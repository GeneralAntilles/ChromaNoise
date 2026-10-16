import ChromaNoiseKit
import Observation

/// Live app state. The UI binds here; every change is pushed straight into the
/// host (the kit's worker samples parameters once per hop, so no debounce).
@MainActor
@Observable
final class PlayerModel {
    let presets = Presets.phonons()

    private(set) var phonon: Phonon {
        didSet { host.apply(phonon) }
    }

    /// Name of the preset the current phonon was loaded from; nil once edited.
    private(set) var selectedPresetName: String?

    /// The current phonon's 32 band amplitudes. Setting this (the painter)
    /// edits the live phonon, so it no longer matches its preset.
    var bandAmps: [Float] {
        get { phonon.amps }
        set {
            phonon.amps = newValue
            selectedPresetName = nil
        }
    }

    var masterVolume: Float = 0.7 {
        didSet { host.setMasterVolume(masterVolume) }
    }

    private(set) var isPlaying = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let host = StandaloneAudioHost()

    init() {
        phonon = Self.normalized(presets[1])   // Pink
        selectedPresetName = presets[1].name
        host.apply(phonon)
        host.setMasterVolume(masterVolume)
    }

    func loadPreset(named name: String) {
        guard let preset = presets.first(where: { $0.name == name }) else { return }
        phonon = Self.normalized(preset)
        selectedPresetName = name
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

    /// Presets are stored relative to band 0 (Blue peaks near 14×), but the
    /// painter's slider scale tops out at amp 1. The kit normalizes to
    /// constant power, so rescaling to peak = 1 leaves the sound unchanged.
    private static func normalized(_ preset: Phonon) -> Phonon {
        var p = preset
        if let peak = p.amps.max(), peak > 0 {
            p.amps = p.amps.map { $0 / peak }
        }
        return p
    }
}
