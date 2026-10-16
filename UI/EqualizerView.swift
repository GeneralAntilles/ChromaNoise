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

    @Environment(\.colorScheme) private var colorScheme

    private static let centers = BandMath.bandCenters()
    private static let darkColors = bandPalette(forDarkBackground: true)
    private static let lightColors = bandPalette(forDarkBackground: false)
    private static let capHeight: CGFloat = 4
    /// Axis ticks; bands are log-spaced, so x ∝ log(f / 100 Hz).
    private static let axisTicks: [(hz: Double, label: String)] = [
        (100, "100"), (200, "200"), (500, "500"), (1000, "1k"),
        (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k"),
    ]
    /// VoiceOver adjust step: 1/20 of the slider = 3 dB.
    private static let accessibilityStep: Float = 0.05

    var body: some View {
        VStack(spacing: 4) {
            bars
            frequencyAxis
                .frame(height: 12)
        }
    }

    private var bars: some View {
        GeometryReader { geometry in
            let colors = colorScheme == .dark ? Self.darkColors : Self.lightColors
            Canvas { context, size in
                let slot = size.width / CGFloat(amps.count)
                let gap = max(1, slot * 0.15)
                for (i, amp) in amps.enumerated() {
                    let v = CGFloat(BandMath.ampToSlider(amp))
                    let height = max(Self.capHeight, v * size.height)
                    let rect = CGRect(x: CGFloat(i) * slot + gap / 2,
                                      y: size.height - height,
                                      width: slot - gap,
                                      height: height)
                    let hue = colors[i]
                    context.fill(Path(rect), with: .color(hue.opacity(0.3)))
                    // Solid cap marks the level.
                    var cap = rect
                    cap.size.height = Self.capHeight
                    context.fill(Path(cap), with: .color(hue))
                }
            }
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

    private var frequencyAxis: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = log(DSPConstants.maxFrequency / DSPConstants.minFrequency)
            ForEach(Self.axisTicks, id: \.hz) { tick in
                let x = width * log(tick.hz / DSPConstants.minFrequency) / span
                Text(tick.label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    // Keep the end labels inside the bounds.
                    .position(x: min(max(x, 10), width - 10), y: geometry.size.height / 2)
            }
        }
        .accessibilityHidden(true)   // each band already speaks its frequency
    }

    /// One hue per band, sweeping warm → cool with frequency: red at 100 Hz to
    /// violet at 20 kHz. Caps must reach 3:1 against the row background, so on
    /// light backgrounds each hue is darkened in linear light just enough to
    /// cap its luminance (yellows/greens darken most; reds/blues barely).
    private static func bandPalette(forDarkBackground dark: Bool) -> [Color] {
        (0..<DSPConstants.bandCount).map { band in
            let hue = 0.8 * Double(band) / Double(DSPConstants.bandCount - 1)
            // Dark: lighter tints keep blue/violet ≥ 3:1 against #1C1C1E.
            let (r, g, b) = linearRGB(hue: hue, saturation: dark ? 0.65 : 0.9)
            guard !dark else {
                return Color(.sRGBLinear, red: r, green: g, blue: b)
            }
            // Contrast vs white = 1.05 / (L + 0.05) ≥ 3.0 → L ≤ 0.30; aim 0.27.
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let scale = min(1, 0.27 / luminance)
            return Color(.sRGBLinear, red: r * scale, green: g * scale, blue: b * scale)
        }
    }

    /// HSV (brightness 1) → linear-light RGB.
    private static func linearRGB(hue: Double, saturation s: Double) -> (Double, Double, Double) {
        let h = hue * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) {
        case 0: (r1, g1, b1) = (1, x, 0)
        case 1: (r1, g1, b1) = (x, 1, 0)
        case 2: (r1, g1, b1) = (0, 1, x)
        case 3: (r1, g1, b1) = (0, x, 1)
        case 4: (r1, g1, b1) = (x, 0, 1)
        default: (r1, g1, b1) = (1, 0, x)
        }
        // Desaturate toward white in sRGB, then decode to linear light.
        func linear(_ c: Double) -> Double {
            let v = 1 - s * (1 - c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return (linear(r1), linear(g1), linear(b1))
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
