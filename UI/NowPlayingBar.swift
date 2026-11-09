import SwiftUI

/// Mini player: what's playing and Play/Pause on top, then volume, the
/// sleep timer and the "more" menu. The clocks are system timer texts —
/// SwiftUI updates them only while on screen, so they cost nothing in the
/// background or with the display off.
struct NowPlayingBar: View {
    @Bindable var model: PlayerModel
    /// Caps the bar's contents on wide windows; the material spans the width.
    var maxContentWidth: CGFloat = .infinity
    /// Wide layouts: a card in the controls column, edges aligned with the
    /// cards above, instead of a full-width bar.
    var isCard = false
    /// Opens the About sheet from the bar's "more" menu.
    var showAbout: () -> Void

    /// Landscape iPhone: a shorter bar leaves room for the controls above.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isShort: Bool { verticalSizeClass == .compact }

    private static let timerChoices = [5, 15, 30, 60, 90]
    private static let cardCornerRadius: CGFloat = 24

    var body: some View {
        let content = VStack(spacing: isShort ? 2 : 6) {
            HStack(spacing: 8) {
                status
                if model.isEdited {
                    revertButton
                }
                Spacer(minLength: 0)
                playButton
            }
            HStack(spacing: 4) {
                volumeSlider
                sleepTimerMenu
                moreMenu
            }
        }
        .frame(maxWidth: maxContentWidth)

        if isCard {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, isShort ? 8 : 12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        } else {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, isShort ? 8 : 12)
                .frame(maxWidth: .infinity)
                // Opaque-ish bar material: the Form scrolls beneath.
                .background(.bar)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(model.displayName)
                    .lineLimit(1)
                if model.isEdited {
                    // Only the name truncates; the mark always shows.
                    Text(" · Edited")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .font(.headline)
            Group {
                if let end = model.sleepTimer?.end, model.isPlaying {
                    // With a timer set, when it ends matters more than how
                    // long it has played.
                    Text("Stops at \(end.formatted(date: .omitted, time: .shortened))")
                } else if let started = model.playStartedAt {
                    Text("Playing \(Text(started, style: .timer))")
                } else {
                    Text("Paused")
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Drops edits to the selected sound; shown only while it's edited.
    private var revertButton: some View {
        Button(action: model.revert) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.title3)
                .frame(width: 44, height: 44)   // full touch target
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Revert to \(model.displayName)")
    }

    // Always on screen, unlike the scrolling form above.
    private var volumeSlider: some View {
        Slider(value: $model.masterVolume, in: 0...1) {
            Text("Volume")
        } minimumValueLabel: {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    private var playButton: some View {
        Button(action: model.togglePlayback) {
            // Label keeps "Play"/"Pause" as the accessibility label.
            Label(model.isPlaying ? "Pause" : "Play",
                  systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                .labelStyle(.iconOnly)
                .font(.title2.weight(.semibold))
                .frame(width: isShort ? 36 : 44, height: isShort ? 36 : 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
    }

    /// About and the hosted help pages. Living in the bar keeps the
    /// screen free of a navigation bar on every layout.
    private var moreMenu: some View {
        Menu {
            Button("About ChromaNoise", systemImage: "info.circle", action: showAbout)
            if let url = AboutView.supportURL {
                Link(destination: url) { Label("Help & Support", systemImage: "questionmark.circle") }
            }
            if let url = AboutView.privacyPolicyURL {
                Link(destination: url) { Label("Privacy Policy", systemImage: "hand.raised") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                // Color, not the hierarchical style: in a Menu label that would
                // resolve against the tint and stay indigo.
                .foregroundStyle(Color.secondary)
                .frame(width: 44, height: 44)   // full touch target
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    private var sleepTimerMenu: some View {
        Menu {
            Picker("Sleep Timer", selection: timerSelection) {
                Text("Off").tag(Int?.none)
                ForEach(Self.timerChoices, id: \.self) { minutes in
                    Text("\(minutes) min").tag(Int?.some(minutes))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                if let end = model.sleepTimer?.end {
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        .monospacedDigit()
                } else {
                    Text("Sleep")
                }
            }
            .font(.subheadline.weight(.medium))
            // Neutral; a running countdown reads at full strength.
            .foregroundStyle(model.sleepTimer == nil ? Color.secondary : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // Keep Off first even when the menu opens upward (iPad).
        .menuOrder(.fixed)
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(model.sleepTimer.map {
            "Ends at \($0.end.formatted(date: .omitted, time: .shortened))"
        } ?? "Off")
    }

    private var timerSelection: Binding<Int?> {
        Binding(get: { model.sleepTimer?.minutes },
                set: { model.setSleepTimer(minutes: $0) })
    }
}
