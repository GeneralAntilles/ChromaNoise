import SwiftData
import SwiftUI

@main
struct ChromaNoiseApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: StoredPhonon.self)
    }
}
