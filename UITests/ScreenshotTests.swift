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
        shoot("02-swell", scene: "swell") { app in
            // Scroll the form (not the painter) until the swell controls show.
            let period = app.sliders["Swell period"]
            for _ in 0..<3 where !period.isHittable {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                start.press(forDuration: 0.05,
                            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)))
            }
        }
        shoot("03-sleep", scene: "sleep") { app in
            app.buttons["Sleep timer"].tap()
            _ = app.buttons["30 min"].waitForExistence(timeout: 5)
        }
        shoot("04-landscape", scene: "landscape", orientation: .landscapeLeft)
    }

    @MainActor
    private func shoot(_ name: String, scene: String,
                       orientation: UIDeviceOrientation = .portrait,
                       prepare: (XCUIApplication) -> Void = { _ in }) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-screenshot", scene]
        app.launch()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20), "\(scene): never started playing")
        // Some displays don't rotate (iPhone Duo's folded outer screen);
        // skip landscape there rather than save a duplicate portrait shot.
        if orientation.isLandscape, app.frame.width < app.frame.height {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            return
        }
        prepare(app)
        sleep(2)   // let animations settle and the clocks tick past 0:00

        // Landscape captures come back as portrait pixels plus an orientation
        // tag; redraw so the PNG itself is upright (App Store Connect reads
        // pixels, not tags).
        let shot = screenshotOfScreen(showing: app)
        let format = UIGraphicsImageRendererFormat()
        format.scale = shot.scale
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(at: .zero)
        }
        guard let png = upright.pngData() else {
            return XCTFail("\(name): couldn't encode PNG")
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
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
