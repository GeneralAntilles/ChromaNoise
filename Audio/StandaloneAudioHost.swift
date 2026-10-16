import AVFoundation
import ChromaNoiseKit

/// v1 host: owns the AVAudioSession and AVAudioEngine and bridges an
/// AVAudioSourceNode to the host-agnostic `NoiseEngine`. A future AUv3 target
/// replaces this file, not the kit.
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

    /// Called on the main queue whenever the host starts or stops by itself
    /// (interruption, route change, failed engine restart) — not for `start()`
    /// / `stop()` calls, whose result the caller already knows.
    var onRunningChange: ((Bool) -> Void)?

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: avEngine,
                               queue: .main) { [weak self] _ in
                self?.handleConfigurationChange()
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                               queue: .main) { [weak self] note in
                self?.handleInterruption(note)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                               queue: .main) { [weak self] note in
                self?.handleRouteChange(note)
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        stop()
    }

    // MARK: transport

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Non-mixable .playback: required to become the Now Playing app
        // (lock-screen controls), and keeps audio alive in the background.
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        do {
            try startEngine()
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        isRunning = true
        // Only a successful start supersedes a pending resume: pressing Play
        // mid-interruption fails, and `.shouldResume` must still work after.
        resumeAfterInterruption = false
    }

    /// User pause: stop rendering but keep the session active, so we stay
    /// the Now Playing app and lock-screen Play keeps routing to us. Also
    /// cancels a pending interruption resume (an explicit pause wins).
    func pause() {
        resumeAfterInterruption = false
        guard isRunning else { return }
        stopEngine()
        isRunning = false
    }

    /// Done playing (Stop, sleep timer, headphones gone): also release the
    /// session so other apps' audio can resume.
    func stop() {
        pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Interrupted while playing, and will resume on `.shouldResume`.
    var isAwaitingResume: Bool { resumeAfterInterruption }

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

        // The render block must do nothing but hand raw pointers to the kit.
        let noise = self.noise
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            noise.render(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
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
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            onRunningChange?(false)
        }
    }

    // MARK: system events

    /// Phone call, Siri, alarm…: the system has already silenced and
    /// deactivated us at `.began`. Resume only if we were playing and the
    /// system passes `.shouldResume` (it omits it when, e.g., another app
    /// took over playback).
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            guard isRunning else { return }
            stopEngine()
            isRunning = false
            resumeAfterInterruption = true
            onRunningChange?(false)

        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                .contains(.shouldResume)
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            guard shouldResume, (try? start()) != nil else { return }
            onRunningChange?(true)

        @unknown default:
            break
        }
    }

    /// Headphones unplugged / Bluetooth gone: pause rather than suddenly
    /// playing out of the speaker. Never auto-resumes.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
        else { return }
        // Also cancel a pending resume: unplugging mid-interruption must not
        // have `.shouldResume` restart us on the speaker.
        resumeAfterInterruption = false
        guard isRunning else { return }
        stop()
        onRunningChange?(false)
    }

    enum HostError: Error {
        case unsupportedFormat(Double)
    }
}
