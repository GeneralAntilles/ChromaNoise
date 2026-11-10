import AVFoundation
import ChromaNoiseKit
import os

/// v1 host: owns the AVAudioSession and AVAudioEngine and bridges an
/// AVAudioSourceNode to the host-agnostic `NoiseEngine`. A future AUv3 target
/// replaces this file, not the kit.
///
/// Main-actor isolated; session (de)activation, which can block for a while,
/// happens asynchronously off the main thread.
@MainActor
final class StandaloneAudioHost: AudioHost, TransportBackend {
    /// Largest pull iOS makes per render callback (it grows to 4096 frames
    /// when the screen locks). Sizes the kit's ring lead.
    private static let maxFramesPerRender = 4096

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChromaNoise",
                                    category: "audio")

    private let noise = NoiseEngine()
    private var avEngine = AVAudioEngine()
    /// The media server restarted: `avEngine` is dead, and the next start
    /// replaces it.
    private var engineIsStale = false
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    /// Tied to the current `avEngine`, and replaced with it.
    private var configurationObserver: NSObjectProtocol?
    /// Play/pause policy and its bookkeeping; this class is its backend.
    private lazy var transport: TransportDriver = {
        let driver = TransportDriver()
        driver.backend = self
        return driver
    }()

    var state: TransportMachine.State { transport.state }

    /// Called on the main actor after every transport state change, whether
    /// requested (play, pause) or not (interruption, route change).
    var onStateChange: ((TransportMachine.State) -> Void)? {
        get { transport.onStateChange }
        set { transport.onStateChange = newValue }
    }

    init() {
        let center = NotificationCenter.default
        // Delivered on the main queue, so main-actor state is safe to touch.
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                               queue: .main) { [weak self] note in
                let info = InterruptionInfo(note)
                MainActor.assumeIsolated { self?.handleInterruption(info) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                               queue: .main) { [weak self] note in
                let deviceGone = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
                MainActor.assumeIsolated { self?.handleRouteChange(deviceGone: deviceGone) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMediaServicesReset() }
            },
        ]
        observeConfigurationChanges()
    }

    deinit {
        // The app's one host lives as long as the process; nothing to stop.
        observers.forEach(NotificationCenter.default.removeObserver)
        configurationObserver.map(NotificationCenter.default.removeObserver)
    }

    /// Follows the current `avEngine`'s route and sample-rate changes.
    private func observeConfigurationChanges() {
        let center = NotificationCenter.default
        configurationObserver.map(center.removeObserver)
        configurationObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: avEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.transport.configurationChanged() }
        }
    }

    // MARK: transport

    /// Registers a start synchronously (so pause, interruptions and route
    /// loss can cancel it from this moment on) and returns it to await.
    /// Concurrent calls share one start; the task throws `CancellationError`
    /// if something superseded it while the session was activating.
    func requestStart() -> Task<Void, Error> {
        transport.requestStart()
    }

    /// User pause: stop rendering but keep the session active, so we stay
    /// the Now Playing app and lock-screen Play keeps routing to us. Also
    /// cancels a pending interruption resume and any start still activating.
    func pause() {
        transport.pause()
    }

    /// Done playing (Stop, sleep timer): also release the session so other
    /// apps' audio can resume.
    func stop() {
        transport.stop()
    }

    // MARK: session (TransportBackend; the driver serializes these)

    func activateSession() async -> Result<Void, Error> {
        let session = AVAudioSession.sharedInstance()
        do {
            // Non-mixable .playback: required to become the Now Playing app
            // (lock-screen controls), and keeps audio alive in the background.
            try session.setCategory(.playback, mode: .default)
        } catch {
            return .failure(error)
        }
        return await Self.activate(session)
    }

    func deactivateSession() async {
        await Self.deactivate(AVAudioSession.sharedInstance())
    }

    /// iOS 27 has asynchronous activation; earlier versions get the blocking
    /// call on a background queue. (The iOS 27 calls need the iOS 27 SDK,
    /// Swift 6.4+; CI's older Xcode builds just the fallback.)
    private static func activate(_ session: AVAudioSession) async -> Result<Void, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                session.activate(options: []) { activated, error in
                    continuation.resume(returning: activated
                        ? .success(())
                        : .failure(error ?? HostError.activationFailed))
                }
                return
            }
            #endif
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try session.setActive(true) })
            }
        }
    }

    private static func deactivate(_ session: AVAudioSession) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in
                    continuation.resume()
                }
                return
            }
            #endif
            DispatchQueue.global(qos: .userInitiated).async {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                continuation.resume()
            }
        }
    }

    // MARK: parameters

    func apply(_ phonon: Phonon) {
        noise.setBandGains(phonon.amps)
        noise.setTremolo(periodSeconds: phonon.tremoloPeriodSeconds, depth: phonon.tremoloDepth)
    }

    func setMasterVolume(_ volume: Float) {
        noise.setMasterVolume(volume)
    }

    // MARK: engine graph (TransportBackend)

    func startEngine() throws {
        if engineIsStale {
            // Only ever between a stop and the next start, so nothing is
            // attached to the engine being dropped.
            avEngine = AVAudioEngine()
            observeConfigurationChanges()
            engineIsStale = false
        }
        let hwRate = avEngine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hwRate > 0 ? hwRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw HostError.unsupportedFormat(sampleRate)
        }

        // Kit contract: prepare only while nothing is rendering.
        noise.prepare(sampleRate: sampleRate, maxFrames: Self.maxFramesPerRender)

        let node = Self.makeSourceNode(format: format, noise: noise)
        avEngine.attach(node)
        avEngine.connect(node, to: avEngine.mainMixerNode, format: format)
        sourceNode = node

        avEngine.prepare()
        do {
            try avEngine.start()
        } catch {
            // Roll back so a retry doesn't attach a second node to the ring.
            stopEngine()
            throw error
        }
    }

    /// Built outside the main actor so the render block, which runs on the
    /// audio thread, never inherits main-actor isolation. It must do nothing
    /// but hand raw pointers to the kit.
    nonisolated private static func makeSourceNode(format: AVAudioFormat,
                                                   noise: NoiseEngine) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            noise.render(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
    }

    func stopEngine() {
        // Stop rendering before tearing the kit down (kit contract).
        avEngine.stop()
        // The count ends with the kit's session; log it for device checks
        // (the first callbacks after a start can count).
        let underruns = noise.underrunCount
        Self.log.info("Engine stopped; render underruns since start: \(underruns)")
        if let sourceNode {
            avEngine.detach(sourceNode)
            self.sourceNode = nil
        }
        noise.teardown()
    }

    // MARK: system events

    /// Phone call, Siri, alarm…: the system has already silenced and
    /// deactivated us at `.began`. Resume only if we were playing and the
    /// system passes `.shouldResume` (it omits it when, e.g., another app
    /// took over playback).
    private func handleInterruption(_ info: InterruptionInfo) {
        switch info.type {
        case .began:
            transport.interruptionBegan()
        case .ended:
            transport.interruptionEnded(shouldResume: info.shouldResume)
        case nil, .some:
            break   // unknown or future interruption types
        }
    }

    /// The parts of an interruption notification we use, read on the
    /// posting thread so the notification itself never crosses actors.
    private struct InterruptionInfo {
        let type: AVAudioSession.InterruptionType?
        let shouldResume: Bool

        nonisolated init(_ note: Notification) {
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            type = raw.flatMap(AVAudioSession.InterruptionType.init)
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
        }
    }

    /// Headphones unplugged / Bluetooth gone: pause rather than suddenly
    /// playing out of the speaker. Never auto-resumes.
    private func handleRouteChange(deviceGone: Bool) {
        if deviceGone { transport.outputDeviceLost() }
    }

    /// The media server crashed and restarted (rare). The system has dropped
    /// the session and everything built on it, so nothing is playing and
    /// nothing will resume: stop, so the UI shows that instead of "playing"
    /// over silence, and start the next Play on a fresh engine.
    private func handleMediaServicesReset() {
        engineIsStale = true
        transport.stop()
    }

    enum HostError: Error {
        case unsupportedFormat(Double)
        case activationFailed
    }
}
