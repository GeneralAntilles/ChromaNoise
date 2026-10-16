import ChromaNoiseKit
import SwiftUI

/// 32-band spectrum painter. Bars show slider positions v ∈ [0,1] (a 60 dB
/// range, top = amp 1); dragging sets the band under the finger to the finger's
/// height, amp = `BandMath.sliderToAmp(v)`. Each change is written straight to
/// `amps` — the kit applies band gains once per hop, so no debounce.
struct EqualizerView: View {
    @Binding var amps: [Float]

    /// Band and slider value of the previous drag sample, for line-painting.
    @State private var lastTouch: (band: Int, value: Float)?

    private static let centers = BandMath.bandCenters()

    /// One hue per band, sweeping warm → cool with frequency: red at 100 Hz
    /// to violet at 20 kHz. Saturation 0.65 keeps the darkest hue (blue) above
    /// 3:1 contrast against the panel.
    private static let bandColors: [Color] = (0..<DSPConstants.bandCount).map { band in
        let t = Double(band) / Double(DSPConstants.bandCount - 1)
        return Color(hue: 0.8 * t, saturation: 0.65, brightness: 1)
    }
    private static let panelColor = Color(white: 0.08)
    private static let capHeight: CGFloat = 4
    /// VoiceOver adjust step: 1/20 of the slider = 3 dB.
    private static let accessibilityStep: Float = 0.05

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Dark panel in both color schemes: the saturated band hues
                // need a dark backdrop to stay legible (yellows wash out on white).
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10),
                             with: .color(Self.panelColor))
                let slot = size.width / CGFloat(amps.count)
                let gap = max(1, slot * 0.15)
                for (i, amp) in amps.enumerated() {
                    let v = CGFloat(BandMath.ampToSlider(amp))
                    let height = max(Self.capHeight, v * size.height)
                    let rect = CGRect(x: CGFloat(i) * slot + gap / 2,
                                      y: size.height - height,
                                      width: slot - gap,
                                      height: height)
                    let hue = Self.bandColors[i]
                    context.fill(Path(rect), with: .color(hue.opacity(0.35)))
                    // Solid cap marks the level.
                    var cap = rect
                    cap.size.height = Self.capHeight
                    context.fill(Path(cap), with: .color(hue))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { paint(at: $0.location, in: geometry.size) }
                    .onEnded { _ in lastTouch = nil }
            )
            // The canvas draws pixels only; give VoiceOver one adjustable
            // synthetic element per band, laid out over its bar.
            .accessibilityLabel("Equalizer")
            .accessibilityChildren {
                HStack(spacing: 0) {
                    ForEach(0..<amps.count, id: \.self) { band in
                        Rectangle()
                            .accessibilityLabel(Self.frequencyLabel(Self.centers[band]))
                            .accessibilityValue(Self.decibelLabel(BandMath.ampToSlider(amps[band])))
                            .accessibilityAdjustableAction { direction in
                                adjust(band: band, direction: direction)
                            }
                    }
                }
            }
        }
    }

    // MARK: painting

    private func paint(at location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let count = amps.count
        let band = min(max(Int(location.x / size.width * CGFloat(count)), 0), count - 1)
        let value = Float(min(max(1 - location.y / size.height, 0), 1))

        var updated = amps
        if let last = lastTouch, last.band != band {
            // The finger skipped bands since the last sample: fill the bands in
            // between along a straight line from the previous point.
            let step = band > last.band ? 1 : -1
            for b in stride(from: last.band + step, through: band, by: step) {
                let t = Float(b - last.band) / Float(band - last.band)
                updated[b] = BandMath.sliderToAmp(last.value + t * (value - last.value))
            }
        } else {
            updated[band] = BandMath.sliderToAmp(value)
        }
        lastTouch = (band, value)
        amps = updated
    }

    private func adjust(band: Int, direction: AccessibilityAdjustmentDirection) {
        var v = BandMath.ampToSlider(amps[band])
        switch direction {
        case .increment: v += Self.accessibilityStep
        case .decrement: v -= Self.accessibilityStep
        @unknown default: return
        }
        amps[band] = BandMath.sliderToAmp(min(max(v, 0), 1))
    }

    // MARK: labels

    private static func frequencyLabel(_ hz: Double) -> String {
        hz >= 1000
            ? String(format: "%.1f kilohertz", hz / 1000)
            : String(format: "%.0f hertz", hz)
    }

    /// Slider position as level relative to the top of the 60 dB range.
    private static func decibelLabel(_ v: Float) -> String {
        "\(Int((60 * (v - 1)).rounded())) decibels"
    }
}

#Preview {
    @Previewable @State var amps = Presets.pink()
    EqualizerView(amps: $amps)
        .frame(height: 200)
        .padding()
}
