// Renders the App Store product page header (iOS 27): 3840×1646 (21:9),
// no alpha. The spectrum bars span the full canvas as atmosphere; the
// tagline sits in Apple's art safe area (1646×661 at x 1097, y 493 from
// the top left), the part every device and orientation shows.
// Spec: developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications
//
//   swift tools/make_header.swift screenshots/header.png

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 3840, height = 1646
let safeArea = CGRect(x: 1097, y: 493, width: 1646, height: 661)   // top-left origin
let output = CommandLine.arguments.dropFirst().first ?? "header.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("no context")
}
let w = CGFloat(width), h = CGFloat(height)

// The icon's background: near-black navy, lighter at the top.
let background = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.13, green: 0.14, blue: 0.24, alpha: 1),
    CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: h), end: .zero, options: [])

/// HSV → sRGB, the app's band palette (red at low bands → violet).
func color(hue: Double, saturation s: Double, brightness v: Double, alpha: Double) -> CGColor {
    let h = hue * 6
    let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
    let (r, g, b): (Double, Double, Double)
    switch Int(h) {
    case 0: (r, g, b) = (1, x, 0)
    case 1: (r, g, b) = (x, 1, 0)
    case 2: (r, g, b) = (0, 1, x)
    case 3: (r, g, b) = (0, x, 1)
    case 4: (r, g, b) = (x, 0, 1)
    default: (r, g, b) = (1, 0, x)
    }
    func c(_ u: Double) -> CGFloat { CGFloat(v * (1 - s * (1 - u))) }
    return CGColor(srgbRed: c(r), green: c(g), blue: c(b), alpha: CGFloat(alpha))
}

// 32 bars across the full width, styled like the app's dark mode: a dim
// fill with a bright cap. A falling spectrum with a low-mid hump, like a
// painted sound.
let bands = 32
let slot = w / CGFloat(bands)
let gap = slot * 0.2
let cap = 22.0
let floor = h * 0.0
let ceiling = h * 0.92
for i in 0..<bands {
    let t = Double(i) / Double(bands - 1)
    let level = 0.8 - 0.42 * t + 0.16 * exp(-pow((t - 0.2) / 0.11, 2)) + 0.08 * exp(-pow((t - 0.68) / 0.1, 2))
    let barHeight = CGFloat(level) * (ceiling - floor)
    let rect = CGRect(x: CGFloat(i) * slot + gap / 2, y: floor, width: slot - gap, height: barHeight)
    let hue = 0.83 * t
    ctx.setFillColor(color(hue: hue, saturation: 0.75, brightness: 0.55, alpha: 0.32))
    ctx.fill(rect)
    ctx.setFillColor(color(hue: hue, saturation: 0.7, brightness: 1, alpha: 1))
    ctx.fill(CGRect(x: rect.minX, y: rect.maxY - cap, width: rect.width, height: cap))
}

// Darken the middle so the tagline reads over the bars.
let vignette = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.03, green: 0.03, blue: 0.07, alpha: 0.85),
    CGColor(srgbRed: 0.03, green: 0.03, blue: 0.07, alpha: 0),
] as CFArray, locations: [0, 1])!
let center = CGPoint(x: safeArea.midX, y: h - safeArea.midY)
ctx.drawRadialGradient(vignette, startCenter: center, startRadius: 0,
                       endCenter: center, endRadius: safeArea.width * 0.75, options: [])

// Tagline, centered in the safe area (CoreGraphics is y-up).
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let text = NSAttributedString(string: "Paint your own noise", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
])
let framesetter = CTFramesetterCreateWithAttributedString(text)
let fit = CTFramesetterSuggestFrameSizeWithConstraints(
    framesetter, CFRange(), nil, CGSize(width: safeArea.width, height: .greatestFiniteMagnitude), nil)
let box = CGRect(x: safeArea.minX, y: h - safeArea.midY - fit.height / 2,
                 width: safeArea.width, height: ceil(fit.height))
ctx.setShadow(offset: .zero, blur: 40, color: CGColor(gray: 0, alpha: 0.8))
CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: box, transform: nil), nil), ctx)

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("couldn't write \(output)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(output)") }
print("\(output)  \(width)x\(height)")
