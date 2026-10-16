import ChromaNoiseKit
import SwiftUI

/// Pure render of 32 post-curve band amplitudes as slider-height bars, peak
/// band at full height. EqualizerView will layer drag-to-paint on top.
struct BarSpectrum: View {
    let amps: [Float]

    var body: some View {
        let peak = amps.max() ?? 1
        Canvas { context, size in
            let count = amps.count
            guard count > 0 else { return }
            let slot = size.width / CGFloat(count)
            let gap = max(1, slot * 0.15)
            for (i, amp) in amps.enumerated() {
                let v = CGFloat(BandMath.ampToSlider(amp, ref: peak))
                let height = max(2, v * size.height)
                let rect = CGRect(x: CGFloat(i) * slot + gap / 2,
                                  y: size.height - height,
                                  width: slot - gap,
                                  height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Spectrum, \(amps.count) bands")
    }
}
