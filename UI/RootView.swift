import ChromaNoiseKit
import SwiftUI

/// Main screen: spectrum painter, presets, volume, and the now-playing bar.
struct RootView: View {
    @State private var model = PlayerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EqualizerView(amps: $model.bandAmps)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    // Selecting loads the preset's bars; painting deselects
                    // (the phonon no longer matches any preset).
                    PresetBar(model: model)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                Section("Volume") {
                    Slider(value: $model.masterVolume, in: 0...1) {
                        Text("Master volume")
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                NowPlayingBar(model: model)
            }
        }
        // Leaving the foreground covers backgrounding and the app switcher
        // (where a swipe-kill follows), so the last sound survives either.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveState() }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: StoredPhonon.self, inMemory: true)
}
