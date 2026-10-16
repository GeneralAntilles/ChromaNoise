import XCTest

/// Enforces the kit's AUv3-readiness contract: ChromaNoiseKit must never
/// import AVFoundation or touch AVAudioSession. An AUv3 extension runs in the
/// host's process where the host owns the audio session; keeping these symbols
/// out of the kit makes that violation impossible at compile time.
final class HostAgnosticismTests: XCTestCase {

    func testKitSourcesNeverImportAVFoundation() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourcesDir = testsDir
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/ChromaNoiseKit")

        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil))

        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            // Check code only: doc comments may legitimately name the banned APIs.
            let source = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
                .joined(separator: "\n")
            for banned in ["import AVFoundation", "import AVFAudio", "AVAudioSession"] {
                XCTAssertFalse(source.contains(banned),
                               "\(url.lastPathComponent) contains '\(banned)' — the kit must stay host-agnostic")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 5, "suspiciously few source files scanned")
    }
}
