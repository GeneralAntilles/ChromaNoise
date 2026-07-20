import Foundation

/// Host-agnostic engine facade. Knows nothing about AVFoundation — the
/// standalone app wraps `render` in an AVAudioSourceNode render block, and a
/// future AUv3 target wraps the same call in an internalRenderBlock. Never
/// touch AVAudioSession from this class or anywhere else in the kit.
public final class NoiseEngine {
    /// Fixed linear headroom so a full white spectrum at master 1.0 stays in
    /// the near-linear region of the tanh soft limiter.
    private static let headroom: Float = 0.5

    private var sampleRate: Double = 48000
    private var leftStream: NoiseStream?
    private var rightStream: NoiseStream?
    private var ring: RenderRingBuffer?
    private var worker: Thread?
    private var running = false

    // Staged parameters, guarded by paramLock. Read by the worker at hop
    // boundaries — never by the render thread, so a lock is fine here.
    private let paramLock = NSLock()
    private var stagedBandAmps = [Float](repeating: 1, count: DSPConstants.bandCount)
    private var stagedMasterVolume: Float = 0.7
    private var stagedTremolo = Tremolo()
    private var gainDirty = true

    public init() {}

    // MARK: lifecycle

    public func prepare(sampleRate: Double, maxFrames: Int) {
        teardown()
        self.sampleRate = sampleRate
        // Decorrelated stereo: two independent noise streams, same gain LUT.
        leftStream = NoiseStream(seed: 0xC0FFEE)
        rightStream = NoiseStream(seed: 0xB0BA)
        gainDirty = true
        // Capacity: 4 hops of lead + whatever the host may pull per callback.
        ring = RenderRingBuffer(capacityFrames: DSPConstants.hop * 4 + maxFrames)
        running = true
        let thread = Thread { [weak self] in self?.workerLoop() }
        thread.name = "ChromaNoiseKit.worker"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()
    }

    public func teardown() {
        running = false
        worker = nil
        ring = nil
        leftStream = nil
        rightStream = nil
    }

    // MARK: parameters (any thread)

    /// 32 post-curve band amplitudes.
    public func setBandGains(_ amps: [Float]) {
        precondition(amps.count == DSPConstants.bandCount)
        paramLock.lock()
        stagedBandAmps = amps
        gainDirty = true
        paramLock.unlock()
    }

    public func setMasterVolume(_ v: Float) {
        paramLock.lock()
        stagedMasterVolume = min(max(v, 0), 1)
        paramLock.unlock()
    }

    public func setTremolo(periodSeconds: Float, depth: Float) {
        paramLock.lock()
        stagedTremolo.periodSeconds = periodSeconds
        stagedTremolo.depth = min(max(depth, 0), 1)
        paramLock.unlock()
    }

    // MARK: render (audio realtime thread)

    /// Copy frames out of the ring. Never blocks; underruns emit silence.
    public func render(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard let ring else {
            for i in 0..<frameCount {
                left[i] = 0
                right[i] = 0
            }
            return
        }
        ring.read(into: left, right, count: frameCount)
    }

    // MARK: worker

    private func workerLoop() {
        let hop = DSPConstants.hop
        var outL = [Float](repeating: 0, count: hop)
        var outR = [Float](repeating: 0, count: hop)
        var envelope = [Float](repeating: 1, count: hop)
        var tremolo = Tremolo()

        while running {
            guard let ring, let leftStream, let rightStream else { break }
            guard ring.availableToWrite >= hop else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            paramLock.lock()
            let master = stagedMasterVolume
            tremolo.periodSeconds = stagedTremolo.periodSeconds
            tremolo.depth = stagedTremolo.depth
            if gainDirty {
                let gain = GainLUT.build(bandAmps: stagedBandAmps, sampleRate: sampleRate)
                leftStream.gain = gain
                rightStream.gain = gain
                gainDirty = false
            }
            paramLock.unlock()

            leftStream.processHop(into: &outL)
            rightStream.processHop(into: &outR)

            // One envelope, shared by both channels → master + headroom → soft limit.
            if tremolo.isActive {
                tremolo.fillEnvelope(into: &envelope, count: hop, sampleRate: sampleRate)
                let scale = master * Self.headroom
                for i in 0..<hop {
                    outL[i] = tanh(outL[i] * envelope[i] * scale)
                    outR[i] = tanh(outR[i] * envelope[i] * scale)
                }
            } else {
                let scale = master * Self.headroom
                for i in 0..<hop {
                    outL[i] = tanh(outL[i] * scale)
                    outR[i] = tanh(outR[i] * scale)
                }
            }

            ring.write(left: outL, right: outR, count: hop)
        }
    }
}
