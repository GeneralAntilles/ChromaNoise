import Atomics
import Foundation

/// Host-agnostic engine facade. Knows nothing about AVFoundation — the
/// standalone app wraps `render` in an AVAudioSourceNode render block, and a
/// future AUv3 target wraps the same call in an internalRenderBlock. Never
/// touch the audio session from this class or anywhere else in the kit.
///
/// Lifecycle contract (same as AUv3 allocate/deallocateRenderResources): the
/// host must not be pulling `render` while `prepare` or `teardown` runs — stop
/// the AVAudioEngine (or let the AU host deallocate) first.
public final class NoiseEngine {
    /// Fixed linear headroom so a full white spectrum at master 1.0 stays in
    /// the near-linear region of the tanh soft limiter.
    private static let headroom: Float = 0.5

    /// Everything one worker thread owns. A fresh session per `prepare` means
    /// a stopping worker can never touch the next session's ring or streams.
    private final class Session {
        let sampleRate: Double
        let ring: RenderRingBuffer
        /// Frames the worker keeps queued ahead of the render thread. This, not
        /// the ring capacity, sets parameter-to-ear latency.
        let targetLead: Int
        let left = NoiseStream(seed: 0xC0FFEE)
        let right = NoiseStream(seed: 0xB0BA)
        let running = ManagedAtomic<Bool>(true)
        let finished = DispatchSemaphore(value: 0)

        init(sampleRate: Double, maxFrames: Int) {
            self.sampleRate = sampleRate
            // Two hops of cushion past the largest host pull: the worker has
            // ≥2 hops (~42 ms) to refill after any callback.
            self.targetLead = DSPConstants.hop * 2 + maxFrames
            self.ring = RenderRingBuffer(capacityFrames: targetLead + DSPConstants.hop)
        }
    }

    private var session: Session?
    /// The render thread's view of the ring: unmanaged so the realtime path
    /// does no retain/release. Only written while the host isn't rendering.
    private var renderRing: Unmanaged<RenderRingBuffer>?

    /// Staged parameters, guarded by `lock`. Read by the worker at hop
    /// boundaries — never by the render thread, so a lock is fine here. Shared
    /// with the worker so the thread never retains the engine itself.
    private final class Parameters {
        let lock = NSLock()
        var bandAmps = [Float](repeating: 1, count: DSPConstants.bandCount)
        var masterVolume: Float = 0.7
        var tremolo = Tremolo()
        var gainDirty = true
    }

    private let params = Parameters()

    public init() {}

    deinit { teardown() }

    // MARK: lifecycle

    public func prepare(sampleRate: Double, maxFrames: Int) {
        teardown()
        let s = Session(sampleRate: sampleRate, maxFrames: maxFrames)
        params.lock.lock()
        params.gainDirty = true
        params.lock.unlock()
        session = s
        renderRing = Unmanaged.passUnretained(s.ring)

        let params = self.params
        let thread = Thread {
            Self.workerLoop(s, params)
            s.finished.signal()
        }
        thread.name = "ChromaNoiseKit.worker"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the worker and waits for it to exit (at most one hop of work).
    public func teardown() {
        guard let s = session else { return }
        renderRing = nil
        session = nil
        s.running.store(false, ordering: .releasing)
        s.finished.wait()
    }

    // MARK: parameters (any thread)

    /// 32 post-curve band amplitudes.
    public func setBandGains(_ amps: [Float]) {
        precondition(amps.count == DSPConstants.bandCount)
        params.lock.lock()
        params.bandAmps = amps
        params.gainDirty = true
        params.lock.unlock()
    }

    public func setMasterVolume(_ v: Float) {
        params.lock.lock()
        params.masterVolume = min(max(v, 0), 1)
        params.lock.unlock()
    }

    public func setTremolo(periodSeconds: Float, depth: Float) {
        params.lock.lock()
        params.tremolo.periodSeconds = periodSeconds
        params.tremolo.depth = min(max(depth, 0), 1)
        params.lock.unlock()
    }

    // MARK: render (audio realtime thread)

    /// Copy frames out of the ring. Never blocks; underruns emit silence.
    public func render(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard let renderRing else {
            left.update(repeating: 0, count: frameCount)
            right.update(repeating: 0, count: frameCount)
            return
        }
        renderRing._withUnsafeGuaranteedRef {
            _ = $0.read(into: left, right, count: frameCount)
        }
    }

    // MARK: worker

    private static func workerLoop(_ s: Session, _ params: Parameters) {
        let hop = DSPConstants.hop
        var outL = [Float](repeating: 0, count: hop)
        var outR = [Float](repeating: 0, count: hop)
        var envelope = [Float](repeating: 1, count: hop)
        var tremolo = Tremolo()
        var lastScale: Float?

        while s.running.load(ordering: .acquiring) {
            guard s.ring.availableToRead < s.targetLead else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            params.lock.lock()
            let master = params.masterVolume
            tremolo.periodSeconds = params.tremolo.periodSeconds
            tremolo.depth = params.tremolo.depth
            let newAmps: [Float]? = params.gainDirty ? params.bandAmps : nil
            params.gainDirty = false
            params.lock.unlock()

            if let newAmps {
                let gain = GainLUT.build(bandAmps: newAmps, sampleRate: s.sampleRate)
                s.left.gain = gain
                s.right.gain = gain
            }

            s.left.processHop(into: &outL)
            s.right.processHop(into: &outR)

            // Master volume is applied after overlap-add, so it gets no free
            // OLA crossfade — ramp it linearly across the hop instead.
            let scale = master * headroom
            let start = lastScale ?? scale
            lastScale = scale
            let step = (scale - start) / Float(hop)

            // One envelope, shared by both channels → master + headroom → soft limit.
            tremolo.fillEnvelope(into: &envelope, count: hop, sampleRate: s.sampleRate)
            for i in 0..<hop {
                let g = envelope[i] * (start + step * Float(i + 1))
                outL[i] = tanh(outL[i] * g)
                outR[i] = tanh(outR[i] * g)
            }

            s.ring.write(left: outL, right: outR, count: hop)
        }
    }
}
