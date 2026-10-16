import XCTest
@testable import ChromaNoiseKit

/// Realtime headroom of the synthesis path. Prints the measured factor so CPU
/// work can be compared run to run; the assertion only guards against a
/// regression back to the unoptimized-build stutter (< 1× realtime).
final class PerformanceTests: XCTestCase {

    /// Seconds of stereo audio produced per second of CPU, at 48 kHz.
    private func realtimeFactor(makeFFT: () -> RealFFT, label: String) -> Double {
        let left = NoiseStream(seed: 1, fft: makeFFT())
        let right = NoiseStream(seed: 2, fft: makeFFT())
        let gain = GainLUT.build(bandAmps: Presets.pink(), sampleRate: 48000)
        left.gain = gain
        right.gain = gain
        var out = [Float](repeating: 0, count: DSPConstants.hop)

        let hops = 400   // ≈ 8.5 s of audio
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<hops {
            left.processHop(into: &out)
            right.processHop(into: &out)
        }
        let cpu = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let audio = Double(hops * DSPConstants.hop) / 48000
        let factor = audio / cpu
        print(String(format: "PERF %@: %.1f× realtime (%.2f%% of one core)", label, factor, 100 / factor))
        return factor
    }

    func testPureSwiftSynthesisIsFasterThanRealtime() {
        let factor = realtimeFactor(makeFFT: { PureSwiftFFT(size: DSPConstants.fftSize) },
                                    label: "PureSwiftFFT")
        // Linux CI's path; shared runners are slow and noisy, so only guard
        // the line that matters (keeping up with realtime).
        XCTAssertGreaterThan(factor, 1)
    }

    func testDefaultSynthesisIsFasterThanRealtime() {
        let factor = realtimeFactor(makeFFT: { makeRealFFT(size: DSPConstants.fftSize) },
                                    label: "default FFT")
        XCTAssertGreaterThan(factor, 1)
    }
}
