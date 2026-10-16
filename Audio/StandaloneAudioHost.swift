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
    private var configObserver: NSObjectProtocol?
    private(set) var isRunning = false

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
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
        try startEngine()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        stopEngine()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

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
        try avEngine.start()
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
        }
    }

    enum HostError: Error {
        case unsupportedFormat(Double)
    }
}
