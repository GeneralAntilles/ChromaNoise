import AppIntents
import SwiftData
import SwiftUI

@main
struct ChromaNoiseApp: App {
    init() {
        // Lets Siri learn the sound names for "Play <sound> in ChromaNoise"
        // (re-run by PresetPicker whenever saved sounds change).
        ChromaNoiseShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(StoredPhonon.container)
    }
}
