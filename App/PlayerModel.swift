import ChromaNoiseKit
import Foundation
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

    /// Which preset the current phonon was loaded from.
    enum PresetSelection: Hashable {
        case builtIn(name: String)
        case saved(id: UUID)
    }

    /// The preset the current phonon came from; nil once painted over.
    private(set) var selection: PresetSelection?

    /// The current phonon's 32 band amplitudes. Setting this (the painter)
    /// edits the live phonon, so it no longer matches its preset.
    var bandAmps: [Float] {
        get { phonon.amps }
        set {
            phonon.amps = newValue
            selection = nil
        }
    }

    var masterVolume: Float = 0.7 {
        didSet { host.setMasterVolume(masterVolume) }
    }

    private(set) var isPlaying = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let host = StandaloneAudioHost()

    init() {
        let initial = presets.first { $0.name == "Brown" } ?? presets[0]
        phonon = Self.normalized(initial)
        selection = .builtIn(name: initial.name)
        host.apply(phonon)
        host.setMasterVolume(masterVolume)
        // Interruptions and route changes start/stop the host on its own;
        // it reports them on the main queue.
        host.onRunningChange = { [weak self] running in
            MainActor.assumeIsolated { self?.isPlaying = running }
        }
    }

    /// Load a sound's bars and modulation. Volume is a global setting, so a
    /// preset's stored `masterVolume` is ignored.
    func load(_ preset: Phonon, as selection: PresetSelection) {
        phonon = Self.normalized(preset)
        self.selection = selection
    }

    /// The sound keeps playing; it just no longer matches a stored preset.
    func savedPresetDeleted(id: UUID) {
        if selection == .saved(id: id) { selection = nil }
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

    /// Built-ins are stored unnormalized (Blue peaks near 14×), but the
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
