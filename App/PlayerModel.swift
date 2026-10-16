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
        didSet { applyVolume() }
    }
    /// Sleep-timer fade multiplier (1 = no fade). Every volume change goes
    /// through `applyVolume`, so moving the slider mid-fade stays faded.
    @ObservationIgnored private var fadeGain: Float = 1

    private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            playStartedAt = isPlaying ? .now : nil
        }
    }
    /// When the current playback started; nil while paused. The UI renders
    /// elapsed time from this with a system timer text (no app-driven ticks).
    private(set) var playStartedAt: Date?
    private(set) var errorMessage: String?

    /// Sleep timer: chosen duration and its deadline, nil when off.
    private(set) var sleepTimerMinutes: Int?
    private(set) var sleepTimerEnd: Date?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// The last stretch of a sleep timer fades master volume to silence.
    static let sleepFadeSeconds: Double = 15

    @ObservationIgnored private let host = StandaloneAudioHost()

    init() {
        let initial = presets.first { $0.name == "Brown" } ?? presets[0]
        phonon = Self.normalized(initial)
        selection = .builtIn(name: initial.name)
        host.apply(phonon)
        applyVolume()
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

    /// What to call the current sound in the UI.
    var displayName: String {
        selection == nil ? "Custom" : phonon.name
    }

    /// The sound keeps playing; it just no longer matches a stored preset.
    func savedPresetDeleted(id: UUID) {
        if selection == .saved(id: id) { selection = nil }
    }

    func savedPresetRenamed(id: UUID, to name: String) {
        if selection == .saved(id: id) { phonon.name = name }
    }

    // MARK: sleep timer

    /// Start (or with nil, cancel) a sleep timer. The timer runs whether or
    /// not audio is playing; at the deadline it stops playback if any.
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        fadeGain = 1   // undo a fade in progress
        applyVolume()
        sleepTimerMinutes = minutes
        guard let minutes else {
            sleepTimerEnd = nil
            return
        }
        let end = Date.now.addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = end
        // The task holds `self` only weakly, per short update, never across
        // a sleep. Task.sleep(for:) uses the continuous clock, so time keeps
        // passing while the device sleeps.
        sleepTask = Task { [weak self] in
            let fadeStart = end.timeIntervalSinceNow - Self.sleepFadeSeconds
            if fadeStart > 0 { try? await Task.sleep(for: .seconds(fadeStart)) }

            // Step the fade gain down; the kit ramps volume each hop, so the
            // steps don't zipper.
            let steps = 60
            let stepSeconds = min(Self.sleepFadeSeconds, max(end.timeIntervalSinceNow, 0)) / Double(steps)
            for i in 1...steps {
                guard !Task.isCancelled, self != nil else { return }
                self?.fadeGain = 1 - Float(i) / Float(steps)
                self?.applyVolume()
                try? await Task.sleep(for: .seconds(stepSeconds))
            }
            guard !Task.isCancelled else { return }
            self?.sleepTimerExpired()
        }
    }

    private func sleepTimerExpired() {
        // Unconditional: also clears a pending interruption resume, so an
        // interruption mid-fade can't restart audio after the deadline.
        host.stop()
        isPlaying = false
        fadeGain = 1   // ready for the next Play
        applyVolume()
        sleepTimerMinutes = nil
        sleepTimerEnd = nil
        sleepTask = nil
    }

    private func applyVolume() {
        host.setMasterVolume(masterVolume * fadeGain)
    }

    func togglePlayback() {
        if host.isRunning {
            host.stop()
            // A manual pause ends the night; interruptions don't.
            setSleepTimer(minutes: nil)
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
