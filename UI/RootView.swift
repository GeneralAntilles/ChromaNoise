import ChromaNoiseKit
import SwiftUI

/// Main screen: spectrum painter, presets, swell, and the now-playing bar
/// (which holds volume and transport). Tall windows stack everything in one
/// form; wide ones (landscape, iPad) put the painter beside the controls.
struct RootView: View {
    @State private var model = PlayerModel.shared
    @State private var showingAbout = false
    /// How much a tall window's painter grows (or shrinks) so the form
    /// ends right above the now-playing bar instead of leaving a gap.
    @State private var equalizerFit: CGFloat = 0
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
        let isTallWindow = size.height >= 900
        let baseHeight = isTallWindow ? min(size.height * 0.45, 720) : 220
        let fitRange = (size.height * 0.3 - baseHeight)...(size.height * 0.6 - baseHeight)
        let equalizerHeight = isTallWindow
            ? baseHeight + min(max(equalizerFit, fitRange.lowerBound), fitRange.upperBound)
            : baseHeight
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
        .modifier(FillScrollSlack(enabled: isTallWindow, fit: $equalizerFit, range: fitRange))
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

/// Feeds a scroll view's slack (visible height left over below its
/// content; negative when it overflows) into `fit`, clamped to `range`, so
/// a flexible view inside can take up the difference. One adjustment
/// settles it: the content then fits exactly, and the slack reads zero.
/// iOS 17 has no scroll geometry; the base height stands there.
private struct FillScrollSlack: ViewModifier {
    let enabled: Bool
    @Binding var fit: CGFloat
    let range: ClosedRange<CGFloat>

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height - geometry.contentInsets.top
                    - geometry.contentInsets.bottom - geometry.contentSize.height
            } action: { _, slack in
                guard enabled, abs(slack) > 1 else { return }
                fit = min(max(fit + slack, range.lowerBound), range.upperBound)
            }
        } else {
            content
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: StoredPhonon.self, inMemory: true)
}
