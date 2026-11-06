import ChromaNoiseKit
import SwiftUI
import UIKit

/// Square Now Playing artwork: the current sound's 32 bars on the app
/// icon's dark field. Always dark, since the lock screen tints around it.
struct SpectrumArtwork: View {
    let amps: [Float]

    var body: some View {
        Canvas { context, size in
            let inset = size.width * 0.12
            let plot = CGRect(x: inset, y: inset, width: size.width - 2 * inset,
                              height: size.height - 2 * inset)
            let slot = plot.width / CGFloat(amps.count)
            let gap = slot * 0.22
            let cap = max(2, plot.height * 0.02)
            for (i, amp) in amps.enumerated() {
                let v = CGFloat(BandMath.ampToSlider(amp))
                let height = max(cap, v * plot.height)
                let rect = CGRect(x: plot.minX + CGFloat(i) * slot + gap / 2,
                                  y: plot.maxY - height, width: slot - gap, height: height)
                let hue = EqualizerView.darkColors[i]
                context.fill(Path(rect), with: .color(hue.opacity(0.32)))
                context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cap)),
                             with: .color(hue))
            }
        }
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.18),
                                    Color(red: 0.03, green: 0.03, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom))
    }

    /// Renders an opaque image for `MPMediaItemArtwork`.
    @MainActor
    static func image(amps: [Float], side: CGFloat = 600) -> UIImage? {
        let renderer = ImageRenderer(content: SpectrumArtwork(amps: amps)
            .frame(width: side, height: side))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

#Preview {
    SpectrumArtwork(amps: Presets.pink())
        .frame(width: 300, height: 300)
}
