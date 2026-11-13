import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Captures App Store screenshots of the staged scenes in
/// App/ScreenshotScenario.swift. Run via tools/screenshots.sh, which sets the
/// status bar and exports the attachments as PNGs.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenshots() {
        shoot("01-paint", scene: "paint")
        shoot("02-sleep", scene: "sleep")
        shoot("03-favorites", scene: "favorites")
    }

    @MainActor
    private func shoot(_ name: String, scene: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-screenshot", scene]
        app.launch()
        // The status line, not the Pause button: that shows as soon as a
        // start is under way.
        let playing = NSPredicate(format: "label CONTAINS 'Playing' OR label CONTAINS 'Stops at'")
        XCTAssertTrue(app.descendants(matching: .any).matching(playing).firstMatch
            .waitForExistence(timeout: 20), "\(scene): never started playing")
        sleep(2)   // let animations settle and the clocks tick past 0:00

        guard let png = Self.opaquePNG(screenshotOfScreen(showing: app)) else {
            return XCTFail("\(name): couldn't encode PNG")
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    /// The capture as an upright PNG without an alpha channel. Landscape
    /// captures come back as portrait pixels plus an orientation tag, and
    /// App Store Connect reads pixels, not tags; it also refuses images with
    /// an alpha channel, which `UIImage.pngData()` writes even for an opaque
    /// image. So redraw into an RGB-only bitmap and encode that.
    private static func opaquePNG(_ shot: UIImage) -> Data? {
        let width = Int((shot.size.width * shot.scale).rounded())
        let height = Int((shot.size.height * shot.scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // UIKit drawing: applies the orientation tag, y down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        shot.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The screen the app is on. XCUIScreen.main is the iPhone Duo's cover
    /// display even while unfolded (it captures black then), so match the
    /// app's window size instead; other devices have just the one screen.
    @MainActor
    private func screenshotOfScreen(showing app: XCUIApplication) -> UIImage {
        let window = app.frame.size
        for screen in XCUIScreen.screens {
            let image = screen.screenshot().image
            // The capture may be unrotated, so accept either orientation.
            let size = image.size
            if abs(size.width - window.width) < 1 && abs(size.height - window.height) < 1
                || abs(size.width - window.height) < 1 && abs(size.height - window.width) < 1 {
                return image
            }
        }
        return XCUIScreen.main.screenshot().image
    }
}
