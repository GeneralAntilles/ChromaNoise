// Renders the placeholder app icon: 32 hue-swept bars on a dark field,
// shaped like a gently falling (pinkish) spectrum. 1024×1024, no alpha
// (App Store requirement).
//
//   swift tools/make_icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("no context")
}

// Background: near-black navy, slightly lighter at the top.
let background = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.10, green: 0.11, blue: 0.18, alpha: 1),
    CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

/// HSV → sRGB, matching the app's band palette (red at low bands → violet).
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

// Bars live in the icon's safe middle (the system mask rounds the corners).
let bands = 32
let left = 150.0, right = Double(size) - 150
let bottom = 230.0, top = Double(size) - 210
let slot = (right - left) / Double(bands)
let gap = slot * 0.22
let cap = 14.0

for i in 0..<bands {
    let t = Double(i) / Double(bands - 1)
    // Falling spectrum with a soft hump in the low mids.
    let level = 0.88 - 0.5 * t + 0.12 * exp(-pow((t - 0.22) / 0.12, 2))
    let height = level * (top - bottom)
    let rect = CGRect(x: left + Double(i) * slot + gap / 2, y: bottom,
                      width: slot - gap, height: height)
    let hue = 0.8 * t
    ctx.setFillColor(color(hue: hue, saturation: 0.65, brightness: 1, alpha: 0.32))
    ctx.fill(rect)
    ctx.setFillColor(color(hue: hue, saturation: 0.65, brightness: 1, alpha: 1))
    ctx.fill(CGRect(x: rect.minX, y: rect.maxY - cap, width: rect.width, height: cap))
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(output)")
