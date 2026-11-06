import SwiftUI

/// Version, credits, and links. Presented as a sheet from the main screen.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Hosted pages for App Store review; rows are hidden while nil.
    private static let privacyPolicyURL: URL? = nil
    private static let supportURL: URL? = nil
    private static let sourceURL = URL(string: "https://github.com/GeneralAntilles/ChromaNoise")
    private static let chromaDozeURL = URL(string: "https://github.com/pmarks-net/chromadoze")

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Text("ChromaNoise")
                            .font(.title2.bold())
                        Text("Version \(Self.version)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("Paint the spectrum of your own noise.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    Text("ChromaNoise is an independent iOS take on ChromaDoze, Paul Marks's noise generator for Android. It doesn't share ChromaDoze's code.")
                    if let url = Self.chromaDozeURL {
                        Link("ChromaDoze on GitHub", destination: url)
                    }
                } header: {
                    Text("Inspired By")
                }

                Section {
                    Text("ChromaNoise doesn't collect any data. Your sounds stay on this device.")
                    if let url = Self.privacyPolicyURL {
                        Link("Privacy Policy", destination: url)
                    }
                } header: {
                    Text("Privacy")
                }

                Section {
                    if let url = Self.supportURL {
                        Link("Support", destination: url)
                    }
                    if let url = Self.sourceURL {
                        Link("Source Code", destination: url)
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// "1.0 (1)" from the bundle's marketing version and build number.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    AboutView()
}
