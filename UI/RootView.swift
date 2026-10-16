import ChromaNoiseKit
import SwiftUI

/// Bootstrap screen: spectrum painter, preset, volume, play. The phonon
/// library and timer tabs replace this as the milestones land.
struct RootView: View {
    @State private var model = PlayerModel()

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
                Button(action: model.togglePlayback) {
                    Label(model.isPlaying ? "Pause" : "Play",
                          systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: StoredPhonon.self, inMemory: true)
}
