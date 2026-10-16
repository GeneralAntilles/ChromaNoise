import ChromaNoiseKit
import Observation

/// Live app state. The UI binds here; every change is pushed straight into the
/// host (the kit's worker samples parameters once per hop, so no debounce).
@MainActor
@Observable
final class PlayerModel {
    let presets = Presets.phonons()

    var phonon: Phonon = Presets.phonons()[1] {   // Pink
        didSet { host.apply(phonon) }
    }

    var masterVolume: Float = 0.7 {
        didSet { host.setMasterVolume(masterVolume) }
    }

    private(set) var isPlaying = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let host = StandaloneAudioHost()

    init() {
        host.apply(phonon)
        host.setMasterVolume(masterVolume)
    }

    func togglePlayback() {
        if host.isRunning {
            host.stop()
        } else {
            do {
                try host.start()
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't start audio: \(error.localizedDescription)"
            }
        }
        isPlaying = host.isRunning
    }
}
