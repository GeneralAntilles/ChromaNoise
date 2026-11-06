import ChromaNoiseKit
import SwiftUI

/// Main screen: spectrum painter, presets, swell, and the now-playing bar
/// (which holds volume and transport).
struct RootView: View {
    @State private var model = PlayerModel()
    @State private var showingAbout = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EqualizerView(amps: $model.bandAmps)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }

                // Selecting loads the preset's bars; painting deselects
                // (the phonon no longer matches any preset).
                Section {
                    PresetPicker(model: model)
                }

                Section {
                    SwellControls(model: model)
                } header: {
                    Text("Swell")
                } footer: {
                    Text("Slowly raises and lowers the volume, like waves.")
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
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
