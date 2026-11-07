import AppIntents
import ChromaNoiseKit
import SwiftData

// Siri, Shortcuts and Spotlight actions. Audio intents run in the app's
// process without bringing it to the foreground, and drive the same
// `PlayerModel.shared` the UI shows.

/// A sound to play: a built-in preset or one the user saved.
struct SoundEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sound"
    static let defaultQuery = SoundQuery()

    /// "builtin:<name>" or "saved:<uuid>".
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    var selection: PlayerModel.PresetSelection? {
        if id.hasPrefix("builtin:") {
            return .builtIn(name: String(id.dropFirst("builtin:".count)))
        }
        if id.hasPrefix("saved:"), let uuid = UUID(uuidString: String(id.dropFirst("saved:".count))) {
            return .saved(id: uuid)
        }
        return nil
    }

    static func builtIn(_ phonon: Phonon) -> SoundEntity {
        SoundEntity(id: "builtin:\(phonon.name)", name: phonon.name)
    }

    static func saved(_ stored: StoredPhonon) -> SoundEntity {
        SoundEntity(id: "saved:\(stored.id.uuidString)", name: stored.name)
    }
}

struct SoundQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [SoundEntity.ID]) async throws -> [SoundEntity] {
        let all = Self.allSounds()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SoundEntity] {
        Self.allSounds().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SoundEntity] {
        Self.allSounds()
    }

    @MainActor
    static func allSounds() -> [SoundEntity] {
        let builtIns = Presets.phonons().map(SoundEntity.builtIn)
        let descriptor = FetchDescriptor<StoredPhonon>(sortBy: [SortDescriptor(\.createdAt)])
        let saved = (try? StoredPhonon.container.mainContext.fetch(descriptor)) ?? []
        return builtIns + saved.map(SoundEntity.saved)
    }

    /// The phonon behind an entity, or nil if it no longer exists.
    @MainActor
    static func phonon(for entity: SoundEntity) -> Phonon? {
        switch entity.selection {
        case .builtIn(let name):
            return Presets.phonons().first { $0.name == name }
        case .saved(let id):
            let descriptor = FetchDescriptor<StoredPhonon>(predicate: #Predicate { $0.id == id })
            return (try? StoredPhonon.container.mainContext.fetch(descriptor))?.first?.phonon
        case nil:
            return nil
        }
    }
}

enum ChromaNoiseIntentError: Error, CustomLocalizedStringResourceConvertible {
    case soundNotFound
    case couldNotStartAudio

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .soundNotFound: "That sound no longer exists."
        case .couldNotStartAudio: "ChromaNoise couldn't start audio."
        }
    }
}

struct PlaySoundIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Noise"
    static let description = IntentDescription("Plays a sound, or the last one if none is chosen.")

    @Parameter(title: "Sound")
    var sound: SoundEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$sound)")
    }

    init() {}

    init(sound: SoundEntity) {
        self.sound = sound
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = PlayerModel.shared
        if let sound {
            guard let phonon = SoundQuery.phonon(for: sound), let selection = sound.selection else {
                throw ChromaNoiseIntentError.soundNotFound
            }
            model.load(phonon, as: selection)
        }
        guard await model.play() else { throw ChromaNoiseIntentError.couldNotStartAudio }
        // A Siri launch may never show a scene (whose phase change normally
        // saves), so remember the sound now.
        model.saveState()
        return .result()
    }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Noise"
    static let description = IntentDescription("Pauses ChromaNoise.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerModel.shared.pause()
        return .result()
    }
}

struct SetSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription(
        "Plays the current sound, then fades it out and stops after the chosen time.")

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 720))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Stop playing after \(\.$minutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = PlayerModel.shared
        // Start first: a timer on silence would be pointless at bedtime.
        guard await model.play() else { throw ChromaNoiseIntentError.couldNotStartAudio }
        model.setSleepTimer(minutes: minutes)
        return .result()
    }
}

struct ChromaNoiseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySoundIntent(),
            phrases: [
                "Play \(\.$sound) in \(.applicationName)",
                "Play \(\.$sound) noise in \(.applicationName)",
                "Play \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Play Noise",
            systemImageName: "play.fill")
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Stop \(.applicationName)",
            ],
            shortTitle: "Pause Noise",
            systemImageName: "pause.fill")
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start a \(.applicationName) sleep timer",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz")
    }
}
