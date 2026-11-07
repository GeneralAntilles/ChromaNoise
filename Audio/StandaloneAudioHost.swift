import AVFoundation
import ChromaNoiseKit

/// v1 host: owns the AVAudioSession and AVAudioEngine and bridges an
/// AVAudioSourceNode to the host-agnostic `NoiseEngine`. A future AUv3 target
/// replaces this file, not the kit.
///
/// Main-actor isolated; session (de)activation, which can block for a while,
/// happens asynchronously off the main thread.
@MainActor
final class StandaloneAudioHost {
    /// Largest pull iOS makes per render callback (it grows to 4096 frames
    /// when the screen locks). Sizes the kit's ring lead.
    private static let maxFramesPerRender = 4096

    private let noise = NoiseEngine()
    private let avEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false
    /// Playing when an interruption began, so `.shouldResume` may restart us.
    private var resumeAfterInterruption = false
    /// A start in flight (session activating), shared by concurrent callers.
    private var startTask: Task<Void, Error>?
    /// Bumped by pause/stop/interruptions so a start still activating gives
    /// up instead of starting the engine afterwards.
    private var transportGeneration = 0
    /// Every session activation and deactivation runs after the previous
    /// one finishes, so a late activation can't land after a later Stop.
    private var sessionTail: Task<Void, Never>?
    /// The post-interruption resume, cancellable by pause/stop/route loss.
    private var resumeTask: Task<Void, Never>?

    /// Called on the main queue whenever the host starts or stops by itself
    /// (interruption, route change, failed engine restart) — not for `start()`
    /// / `stop()` calls, whose result the caller already knows.
    var onRunningChange: ((Bool) -> Void)?

    init() {
        let center = NotificationCenter.default
        // Delivered on the main queue, so main-actor state is safe to touch.
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: avEngine,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleConfigurationChange() }
            },
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
        ]
    }

    deinit {
        // The app's one host lives as long as the process; nothing to stop.
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: transport

    /// Activates the session and starts rendering. Concurrent calls share
    /// one start. Throws `CancellationError` if pause, stop, an interruption
    /// or route loss came in while the session was still activating.
    func start() async throws {
        try await requestStart().value
    }

    /// Registers a start synchronously (so pause, interruptions and route
    /// loss can cancel it from this moment on) and returns it to await.
    func requestStart() -> Task<Void, Error> {
        if isRunning { return Task {} }
        if let startTask { return startTask }
        let generation = transportGeneration
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer { if self.transportGeneration == generation { self.startTask = nil } }
            try await self.performStart(generation: generation)
        }
        startTask = task
        return task
    }

    private func performStart(generation: Int) async throws {
        // Paused or stopped before this task even ran: don't queue an
        // activation behind that Stop's deactivation.
        guard transportGeneration == generation else { throw CancellationError() }
        let session = AVAudioSession.sharedInstance()
        // Non-mixable .playback: required to become the Now Playing app
        // (lock-screen controls), and keeps audio alive in the background.
        try session.setCategory(.playback, mode: .default)
        let activation = await enqueueSessionOperation { await Self.activate(session) }.value

        // Paused, stopped or interrupted meanwhile: leave the engine off, and
        // report that rather than any activation error. (A Stop has queued
        // its deactivation behind this activation, so the session ends up
        // inactive; a Pause keeps it active, as paused sessions are.)
        guard transportGeneration == generation else { throw CancellationError() }
        try activation.get()
        do {
            try startEngine()
        } catch {
            deactivateSession()
            throw error
        }
        isRunning = true
        // Only a successful start supersedes a pending resume: pressing Play
        // mid-interruption fails, and `.shouldResume` must still work after.
        resumeAfterInterruption = false
    }

    /// User pause: stop rendering but keep the session active, so we stay
    /// the Now Playing app and lock-screen Play keeps routing to us. Also
    /// cancels a pending interruption resume and any start still activating
    /// (an explicit pause wins).
    func pause() {
        cancelPendingStart()
        cancelResume()
        guard isRunning else { return }
        stopEngine()
        isRunning = false
    }

    /// Done playing (Stop, sleep timer, headphones gone): also release the
    /// session so other apps' audio can resume.
    func stop() {
        pause()
        deactivateSession()
    }

    private func cancelPendingStart() {
        transportGeneration += 1
        startTask = nil
    }

    private func cancelResume() {
        resumeAfterInterruption = false
        resumeTask?.cancel()
        resumeTask = nil
    }

    // MARK: session activation (serialized, off the main thread)

    /// Queues `operation` behind every session operation queued so far.
    /// Synchronous, so queue order is call order.
    private func enqueueSessionOperation<T>(
        _ operation: @escaping @MainActor () async -> T
    ) -> Task<T, Never> {
        let previous = sessionTail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        sessionTail = Task { _ = await task.value }
        return task
    }

    /// iOS 27 has asynchronous activation; earlier versions get the blocking
    /// call on a background queue.
    private static func activate(_ session: AVAudioSession) async -> Result<Void, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            if #available(iOS 27.0, *) {
                session.activate(options: []) { activated, error in
                    continuation.resume(returning: activated
                        ? .success(())
                        : .failure(error ?? HostError.activationFailed))
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result { try session.setActive(true) })
                }
            }
        }
    }

    private static func deactivate(_ session: AVAudioSession) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if #available(iOS 27.0, *) {
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in
                    continuation.resume()
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                }
            }
        }
    }

    /// Fire-and-forget deactivation that lets other apps' audio resume,
    /// queued behind any activation still in flight.
    private func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        _ = enqueueSessionOperation { await Self.deactivate(session) }
    }

    /// Interrupted while playing, and will resume on `.shouldResume`.
    var isAwaitingResume: Bool { resumeAfterInterruption }

    /// A start is under way: activating the session, or resuming after an
    /// interruption.
    var isStarting: Bool { startTask != nil || resumeTask != nil }

    // MARK: parameters

    func apply(_ phonon: Phonon) {
        noise.setBandGains(phonon.amps)
        noise.setTremolo(periodSeconds: phonon.tremoloPeriodSeconds, depth: phonon.tremoloDepth)
    }

    func setMasterVolume(_ volume: Float) {
        noise.setMasterVolume(volume)
    }

    // MARK: engine graph

    private func startEngine() throws {
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

    private func stopEngine() {
        // Stop rendering before tearing the kit down (kit contract).
        avEngine.stop()
        if let sourceNode {
            avEngine.detach(sourceNode)
            self.sourceNode = nil
        }
        noise.teardown()
    }

    /// Route or sample-rate change: AVAudioEngine has already stopped itself.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            isRunning = false
            deactivateSession()
            onRunningChange?(false)
        }
    }

    // MARK: system events

    /// Phone call, Siri, alarm…: the system has already silenced and
    /// deactivated us at `.began`. Resume only if we were playing and the
    /// system passes `.shouldResume` (it omits it when, e.g., another app
    /// took over playback).
    private func handleInterruption(_ info: InterruptionInfo) {
        switch info.type {
        case .began:
            // Only actual playback earns a resume; a start still activating
            // is just dropped (it would fail anyway).
            let wasPlaying = isRunning
            cancelPendingStart()
            cancelResume()
            if wasPlaying {
                stopEngine()
                isRunning = false
            }
            // The system has deactivated us already; queueing a deactivation
            // anyway undoes any activation still in flight (even one a Pause
            // already orphaned), so we never hold the session through the
            // interruption. A later resume queues behind it.
            deactivateSession()
            guard wasPlaying else { return }
            resumeAfterInterruption = true
            onRunningChange?(false)

        case .ended:
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            guard info.shouldResume else { return }
            // A Play pressed during the interruption may still be pending
            // (and may fail); resume with a fresh activation instead of
            // sharing its outcome.
            cancelPendingStart()
            // Tracked so Pause, Stop or route loss can cancel it at any point.
            resumeTask = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                let started = (try? await self.start()) != nil
                // Re-check: a pause may have landed after the start finished.
                guard !Task.isCancelled else { return }
                self.resumeTask = nil
                if started, self.isRunning { self.onRunningChange?(true) }
            }

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
        guard deviceGone else { return }
        // Also cancel a pending resume or start, unconditionally: unplugging
        // mid-interruption (or mid-activation) must not restart us on the
        // speaker.
        let wasActive = isRunning || isStarting
        cancelResume()
        cancelPendingStart()
        guard wasActive else { return }
        stop()
        onRunningChange?(false)
    }

    enum HostError: Error {
        case unsupportedFormat(Double)
        case activationFailed
    }
}
