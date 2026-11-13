import SwiftUI

/// Tremolo, presented as a slow "swell": how deep the volume dips and how
/// long one rise-and-fall takes. Period is on a log scale so the slow,
/// wave-like end (where sleep sounds live) gets most of the travel.
struct SwellControls: View {
    @Bindable var model: PlayerModel

    static let periodRange: ClosedRange<Float> = 0.5...30

    var body: some View {
        // Heading inside the card, styled like the preset groups', so the
        // form doesn't spend a header's worth of space between cards.
        VStack(alignment: .leading, spacing: 2) {
            Text("Swell")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text("Slowly raises and lowers the volume, like waves.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .listRowSeparator(.hidden)

        LabeledContent {
            Slider(value: $model.tremoloDepth, in: 0...1) {
                Text("Swell depth")
            }
            .accessibilityValue(depthLabel)
        } label: {
            labelText("Depth", value: depthLabel)
        }

        LabeledContent {
            Slider(value: logPeriod, in: 0...1) {
                Text("Swell period")
            }
            .accessibilityValue(periodLabel)
        } label: {
            labelText("Period", value: periodLabel, dimmed: model.tremoloDepth < 0.001)
        }
        .disabled(model.tremoloDepth < 0.001)
    }

    private func labelText(_ title: String, value: String, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .foregroundStyle(dimmed ? .secondary : .primary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64, alignment: .leading)
        .accessibilityHidden(true)   // the slider speaks its own label and value
    }

    private var depthLabel: String {
        model.tremoloDepth < 0.001 ? "Off" : "\(Int((model.tremoloDepth * 100).rounded()))%"
    }

    private var periodLabel: String {
        let p = model.shownTremoloPeriodSeconds
        return p < 10 ? String(format: "%.1f s", p) : "\(Int(p.rounded())) s"
    }

    /// Slider position 0…1 ↔ period, logarithmically.
    private var logPeriod: Binding<Float> {
        let lo = log(Self.periodRange.lowerBound), hi = log(Self.periodRange.upperBound)
        return Binding(
            get: {
                let p = min(max(model.shownTremoloPeriodSeconds, Self.periodRange.lowerBound),
                            Self.periodRange.upperBound)
                return (log(p) - lo) / (hi - lo)
            },
            set: { model.tremoloPeriodSeconds = exp(lo + $0 * (hi - lo)) })
    }
}
