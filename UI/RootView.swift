import ChromaNoiseKit
import SwiftUI

/// Main screen: spectrum painter, presets, swell, and the now-playing bar
/// (which holds volume and transport). Tall windows stack everything in one
/// form; wide ones (landscape, iPad) put the painter beside the controls.
struct RootView: View {
    @State private var model = PlayerModel.shared
    @State private var showingAbout = false
    @Environment(\.scenePhase) private var scenePhase

    /// Widest the single-column form grows before it gets side margins.
    private static let maxColumnWidth: CGFloat = 700
    private static let wideTopMargin: CGFloat = 16
    /// Inset-grouped cards' side margin.
    private static let cardInset: CGFloat = 16
    /// The form's card inset in wide windows (landscape, iPad).
    private static let wideCardInset: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height * 1.1 {
                wideLayout(width: geometry.size.width)
            } else {
                tallLayout(size: geometry.size)
            }
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        #if DEBUG
        .preferredColorScheme(ScreenshotScenario.current?.colorScheme)
        .task { await ScreenshotScenario.current?.apply(to: model) }
        #endif
        // Leaving the foreground covers backgrounding and the app switcher
        // (where a swipe-kill follows), so the last sound survives either.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveState() }
        }
    }

    /// Portrait: one scrolling form. On tall iPad windows the painter grows
    /// into the room the controls leave, and the column stays a readable width.
    private func tallLayout(size: CGSize) -> some View {
        let equalizerHeight = size.height >= 900 ? min(size.height * 0.45, 720) : 220
        // Never below the inset-grouped default, or the cards lose their insets.
        let margin = max(Self.cardInset, (size.width - Self.maxColumnWidth) / 2)
        return Form {
            Section {
                equalizer
                    .frame(height: equalizerHeight)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            controlSections
        }
        .listSectionSpacing(.compact)
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .contentMargins(.top, 8, for: .scrollContent)
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar(model: model, maxContentWidth: Self.maxColumnWidth) { showingAbout = true }
        }
    }

    /// Landscape / wide: the painter fills the left; the controls scroll on
    /// the right above the now-playing card, whose edges line up with theirs.
    private func wideLayout(width: CGFloat) -> some View {
        HStack(spacing: 16) {
            equalizer
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                // Leading inset matches the form's trailing card inset; top
                // matches the form's first card.
                .padding([.leading, .bottom], Self.wideCardInset)
                .padding(.top, Self.wideTopMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                Form {
                    controlSections
                }
                .listSectionSpacing(.compact)
                .contentMargins(.top, Self.wideTopMargin, for: .scrollContent)

                NowPlayingBar(model: model, isCard: true) { showingAbout = true }
                    // Same insets as the form's cards; bottom matches the painter.
                    .padding([.horizontal, .bottom], Self.wideCardInset)
            }
            .frame(width: min(max(width * 0.5, 340), 480))   // four chips a row on 6.1" phones
        }
        .background(Color(.systemGroupedBackground))
    }

    private var equalizer: some View {
        EqualizerView(amps: $model.bandAmps)
    }

    @ViewBuilder private var controlSections: some View {
        // Selecting loads the preset's bars; painting keeps the selection,
        // marked as edited.
        Section {
            PresetPicker(model: model)
        }

        Section {
            SwellControls(model: model)
        }

        if let error = model.errorMessage {
            Section {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: StoredPhonon.self, inMemory: true)
}
