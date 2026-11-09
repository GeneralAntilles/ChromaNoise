import ChromaNoiseKit
import Foundation
import Observation

/// Live app state. The UI binds here; every change is pushed straight into the
/// host (the kit's worker samples parameters once per hop, so no debounce).
@MainActor
@Observable
final class PlayerModel {
    /// The app's one player: the UI and App Intents drive the same audio.
    static let shared = PlayerModel()

    let presetGroups = Presets.groups()
    let presets = Presets.phonons()

    private(set) var phonon: Phonon {
        didSet {
            host.apply(phonon)
            publishNowPlaying()
        }
    }

    /// Which preset the current phonon was loaded from.
    enum PresetSelection: Hashable, Codable {
        case builtIn(name: String)
        case saved(id: UUID)
    }

    /// The preset the current phonon came from, edited or not; nil for a
    /// sound with no preset behind it (its saved sound was deleted).
    private(set) var selection: PresetSelection? {
        didSet { publishNowPlaying() }
    }

    /// The selected preset's sound as loaded, for Revert and the Edited
    /// mark; nil when there is no selection.
    private(set) var loadedPhonon: Phonon?

    /// Whether the sound has been painted or reshaped since it was loaded.
    var isEdited: Bool {
        guard let loadedPhonon else { return false }
        return phonon.amps != loadedPhonon.amps
            || phonon.tremoloDepth != loadedPhonon.tremoloDepth
            || phonon.tremoloPeriodSeconds != loadedPhonon.tremoloPeriodSeconds
    }

    /// The current phonon's 32 band amplitudes. Setting this (the painter)
    /// edits the live phonon; the selection stays, marked as edited.
    var bandAmps: [Float] {
        get { phonon.amps }
        set { phonon.amps = newValue }
    }

    /// Swell (tremolo) depth, 0 = off.
    var tremoloDepth: Float {
        get { phonon.tremoloDepth }
        set {
            // Presets without swell carry the kit's 1 s default period, a
            // fast pulse. Turning swell on from off starts at a slow wave.
            if phonon.tremoloDepth < 0.001, newValue >= 0.001, phonon.tremoloPeriodSeconds < 2 {
                phonon.tremoloPeriodSeconds = 8
            }
            phonon.tremoloDepth = newValue
        }
    }

    var tremoloPeriodSeconds: Float {
        get { phonon.tremoloPeriodSeconds }
        set { phonon.tremoloPeriodSeconds = newValue }
    }

    var masterVolume: Float = 0.7 {
        didSet { applyVolume() }
    }
    /// Sleep-timer fade multiplier (1 = no fade). Every volume change goes
    /// through `applyVolume`, so moving the slider mid-fade stays faded.
    @ObservationIgnored private var fadeGain: Float = 1

    /// The host's transport state, published by the host on every change.
    private(set) var transport: TransportMachine.State = .idle {
        didSet {
            guard transport.isRunning != oldValue.isRunning else { return }
            // Cleared here, not when the start's awaiter resumes a turn later,
            // so "Playing" never shows next to a stale start error.
            if transport.isRunning { errorMessage = nil }
            playStartedAt = transport.isRunning ? .now : nil
            publishNowPlaying()
        }
    }
    var isPlaying: Bool { transport.isRunning }
    /// When the current playback started; nil while paused. The UI renders
    /// elapsed time from this with a system timer text (no app-driven ticks).
    private(set) var playStartedAt: Date?
    private(set) var errorMessage: String?

    /// A running sleep timer: the chosen duration and its deadline.
    struct SleepTimer: Equatable {
        let minutes: Int
        let end: Date
    }
    /// nil when off.
    private(set) var sleepTimer: SleepTimer?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// The last stretch of a sleep timer fades master volume to silence.
    static let sleepFadeSeconds: Double = 15

    @ObservationIgnored private let host = StandaloneAudioHost()
    @ObservationIgnored private var nowPlaying: NowPlayingController?

    init() {
        if !Self.isScreenshotRun, let saved = Self.loadSavedState() {
            phonon = saved.phonon
            // A built-in removed since (e.g. Grey, Violet) restores as Custom.
            if case .builtIn(let name) = saved.selection, !presets.contains(where: { $0.name == name }) {
                selection = nil
            } else {
                selection = saved.selection
                // States saved before edits kept their selection were unedited.
                loadedPhonon = saved.selection == nil ? nil : saved.loadedPhonon ?? saved.phonon
            }
            masterVolume = saved.masterVolume
        } else {
            let initial = presets.first { $0.name == "Brown" } ?? presets[0]
            phonon = Self.normalized(initial)
            selection = .builtIn(name: initial.name)
            loadedPhonon = phonon
        }
        host.apply(phonon)
        applyVolume()
        // Every transport change, including interruptions and route changes.
        host.onStateChange = { [weak self] state in
            self?.transport = state
        }
        // Remote commands must answer synchronously, so Play reports success
        // once a start is under way; a failure shows in the UI's error row.
        nowPlaying = NowPlayingController(
            play: { [weak self] in self?.startPlaying(); return self != nil },
            pause: { [weak self] in self?.pause(); return self != nil },
            stop: { [weak self] in self?.stop(); return self != nil },
            toggle: { [weak self] in self?.remoteToggle() ?? false })
        publishNowPlaying()
    }


    /// Load a sound's bars and modulation. Volume is a global setting, so a
    /// preset's stored `masterVolume` is ignored.
    func load(_ preset: Phonon, as selection: PresetSelection) {
        phonon = Self.normalized(preset)
        loadedPhonon = phonon
        self.selection = selection
    }

    /// Back to the selected preset as loaded, dropping the edits.
    func revert() {
        guard let loadedPhonon else { return }
        phonon = loadedPhonon
    }

    /// The current sound was written over its saved preset: it is the new
    /// baseline for Revert and no longer counts as edited.
    func savedPresetUpdated(id: UUID) {
        guard selection == .saved(id: id) else { return }
        loadedPhonon = phonon
    }

    /// What to call the current sound in the UI.
    var displayName: String {
        selection == nil ? "Custom" : phonon.name
    }

    /// The sound keeps playing; it just no longer matches a stored preset.
    func savedPresetDeleted(id: UUID) {
        guard selection == .saved(id: id) else { return }
        selection = nil
        loadedPhonon = nil
    }

    func savedPresetRenamed(id: UUID, to name: String) {
        guard selection == .saved(id: id) else { return }
        phonon.name = name
        loadedPhonon?.name = name
    }

    // MARK: sleep timer

    /// Start (or with nil, cancel) a sleep timer. The timer runs whether or
    /// not audio is playing; at the deadline it stops playback if any.
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        fadeGain = 1   // undo a fade in progress
        applyVolume()
        guard let minutes else {
            sleepTimer = nil
            return
        }
        let end = Date.now.addingTimeInterval(Double(minutes) * 60)
        sleepTimer = SleepTimer(minutes: minutes, end: end)
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
        fadeGain = 1   // ready for the next Play
        applyVolume()
        sleepTimer = nil
        sleepTask = nil
    }

    private func applyVolume() {
        // Screenshot runs show playback without making noise.
        host.setMasterVolume(Self.isScreenshotRun ? 0 : masterVolume * fadeGain)
    }

    /// Staged App Store screenshot run (debug builds only).
    private static var isScreenshotRun: Bool {
        #if DEBUG
        ScreenshotScenario.current != nil
        #else
        false
        #endif
    }

    // MARK: transport

    /// The on-screen button: does what its label says. A start still
    /// activating counts as playing, so a quick second tap cancels it.
    func togglePlayback() {
        if isPlaying || transport.isStarting { pause() } else { startPlaying() }
    }

    /// Headphone/Siri toggle: an interruption that will auto-resume (or a
    /// start under way) counts as playing, so a toggle pauses for good.
    private func remoteToggle() -> Bool {
        if transport == .idle { startPlaying() } else { pause() }
        return true
    }

    /// Starts playback without waiting for it (buttons, remote commands).
    /// The start is registered with the host immediately, so a pause,
    /// interruption or unplug right after still cancels it.
    func startPlaying() {
        let start = host.requestStart()
        Task { await finishStart(start) }
    }

    /// Activates audio and starts playing. Returns whether audio is now
    /// playing; false if it failed or was cancelled meanwhile.
    @discardableResult
    func play() async -> Bool {
        await finishStart(host.requestStart())
    }

    private func finishStart(_ start: Task<Void, Error>) async -> Bool {
        do {
            try await start.value
        } catch is CancellationError {
            // Paused, stopped, interrupted or unplugged while starting.
        } catch {
            errorMessage = "Couldn't start audio: \(error.localizedDescription)"
        }
        return isPlaying
    }

    /// User pause (button, lock screen, headphones). Unconditional, so it also
    /// cancels a pending interruption resume. Also ends a sleep timer: a
    /// manual pause ends the night; interruptions don't.
    func pause() {
        host.pause()
        setSleepTimer(minutes: nil)
    }

    /// Remote Stop: like pause, but also releases the audio session.
    func stop() {
        pause()
        host.stop()
    }

    private func publishNowPlaying() {
        nowPlaying?.update(title: displayName, isPlaying: isPlaying)
        nowPlaying?.updateArtwork(amps: phonon.amps)
    }

    // MARK: persistence

    /// The last sound — painted or not — so the app reopens where you left
    /// it. Saved when the app leaves the foreground; never auto-plays.
    private struct SavedState: Codable {
        var phonon: Phonon
        var selection: PresetSelection?
        /// Absent in states saved before edits kept their selection.
        var loadedPhonon: Phonon?
        var masterVolume: Float
    }

    private static let savedStateKey = "lastSound"

    func saveState() {
        guard !Self.isScreenshotRun else { return }   // keep the user's last sound
        let state = SavedState(phonon: phonon, selection: selection,
                               loadedPhonon: loadedPhonon, masterVolume: masterVolume)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.savedStateKey)
        }
    }

    private static func loadSavedState() -> SavedState? {
        guard let data = UserDefaults.standard.data(forKey: savedStateKey),
              var state = try? JSONDecoder().decode(SavedState.self, from: data),
              // Decoding bypasses Phonon's init checks; validate before use.
              isPlayable(state.phonon)
        else { return nil }
        if let loaded = state.loadedPhonon, !isPlayable(loaded) {
            state.loadedPhonon = nil
        }
        state.masterVolume = min(max(state.masterVolume, 0), 1)
        return state
    }

    private static func isPlayable(_ phonon: Phonon) -> Bool {
        phonon.amps.count == DSPConstants.bandCount
            && phonon.amps.allSatisfy { $0.isFinite && $0 >= 0 }
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
