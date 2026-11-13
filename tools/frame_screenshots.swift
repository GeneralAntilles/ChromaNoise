// Frames the raw App Store screenshots from tools/screenshots.sh: a caption
// over the icon's dark navy gradient, the screenshot below with rounded
// corners. Each frame keeps its screenshot's exact pixel size (an App Store
// size) and has no alpha channel (App Store Connect refuses one).
//
//   swift tools/frame_screenshots.swift              # screenshots/ -> screenshots/framed/
//   swift tools/frame_screenshots.swift IN OUT
//
// Captions are keyed by the scene name, the file name without its number
// ("01-paint.png" -> "paint"); a scene without one is skipped. The line
// break is where portrait frames wrap (balanced lines, no orphan word);
// landscape frames have room for one line.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let captions = [
    "paint": "Paint your\nown noise",
    "sleep": "Fall asleep with\na fade-out timer",
    "landscape": "Shape every band,\nfrom rumble to hiss",
]

let arguments = CommandLine.arguments.dropFirst()
let input = URL(fileURLWithPath: arguments.first ?? "screenshots")
let output = URL(fileURLWithPath: arguments.dropFirst().first ?? "screenshots/framed")
let files = FileManager.default
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// Caption in bold white, centered in `box`, wrapped to its width.
func drawCaption(_ text: String, in box: CGRect, fontSize: CGFloat, context: CGContext) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let fit = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(), nil, CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
    // Vertically centered in the box.
    let frameRect = CGRect(x: box.minX, y: box.midY - fit.height / 2,
                           width: box.width, height: ceil(fit.height))
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
    CTFrameDraw(frame, context)
}

func frame(_ shot: CGImage, caption: String) -> CGImage? {
    let width = shot.width, height = shot.height
    let w = CGFloat(width), h = CGFloat(height)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

    // The icon's background: near-black navy, lighter at the top.
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.13, green: 0.14, blue: 0.24, alpha: 1),
        CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: h), end: .zero, options: [])

    // Caption band on top, the screenshot scaled into the rest. Landscape
    // shots have less height to give, so a narrower band.
    let landscape = w > h
    let short = min(w, h)
    let captionHeight = h * (landscape ? 0.16 : 0.15)
    let margin = short * 0.07
    let available = CGRect(x: margin, y: margin * 0.6,
                           width: w - 2 * margin, height: h - captionHeight - margin * 0.6)
    let scale = min(available.width / w, available.height / h)
    let shotRect = CGRect(x: (w - w * scale) / 2, y: available.minY,
                          width: w * scale, height: h * scale)

    drawCaption(landscape ? caption.replacingOccurrences(of: "\n", with: " ") : caption,
                in: CGRect(x: margin, y: shotRect.maxY, width: w - 2 * margin, height: h - shotRect.maxY),
                fontSize: short * (landscape ? 0.06 : 0.072), context: context)

    // Rounded like a device screen, with a soft shadow to lift it. Phone
    // screens have big corners their status bars sit inside; iPad and the
    // Duo's cover display have small ones, which a big radius would clip.
    let isPhone = max(w, h) / min(w, h) > 1.9
    let radius = min(shotRect.width, shotRect.height) * (isPhone ? 0.08 : 0.03)
    let path = CGPath(roundedRect: shotRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -short * 0.01), blur: short * 0.04,
                      color: CGColor(gray: 0, alpha: 0.6))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.interpolationQuality = .high
    context.draw(shot, in: shotRect)
    context.restoreGState()
    // A hairline edge, so dark screenshots don't melt into the background.
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    context.setLineWidth(max(1, short * 0.0015))
    context.strokePath()

    return context.makeImage()
}

let devices = (try? files.contentsOfDirectory(at: input, includingPropertiesForKeys: [.isDirectoryKey]))?
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .filter { $0.standardizedFileURL != output.standardizedFileURL }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
for device in devices {
    let shots = ((try? files.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !shots.isEmpty else { continue }
    let destination = output.appendingPathComponent(device.lastPathComponent)
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    print("==> \(device.lastPathComponent)")
    for url in shots {
        let base = url.deletingPathExtension().lastPathComponent
        let scene = base.split(separator: "-", maxSplits: 1).last.map(String.init) ?? base
        guard let caption = captions[scene] else {
            print("    \(url.lastPathComponent): no caption for \"\(scene)\", skipped")
            continue
        }
        guard let shot = loadImage(url), let framed = frame(shot, caption: caption) else {
            print("    \(url.lastPathComponent): couldn't frame")
            continue
        }
        try writePNG(framed, to: destination.appendingPathComponent(url.lastPathComponent))
        print("    \(url.lastPathComponent)  \(framed.width)x\(framed.height)  \"\(caption.replacingOccurrences(of: "\n", with: " "))\"")
    }
}
