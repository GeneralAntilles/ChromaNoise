import ChromaNoiseKit
import SwiftUI

/// Bootstrap screen: preset, volume, play. The 32-bar painter (EqualizerView),
/// phonon library, and timer tabs replace this as the milestones land.
struct RootView: View {
    @State private var model = PlayerModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BarSpectrum(amps: model.phonon.amps)
                        .frame(height: 160)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    Picker("Preset", selection: $model.phonon) {
                        ForEach(model.presets, id: \.name) { preset in
                            Text(preset.name).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
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
            .navigationTitle("ChromaNoise")
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
}
