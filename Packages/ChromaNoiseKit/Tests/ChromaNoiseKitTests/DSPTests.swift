import XCTest
import ChromaNoiseKit

/// Mirrors tools/reference_dsp.py checks 1–5. Tolerances are Float-scale where
/// the reference used Double.
final class DSPTests: XCTestCase {

    func testBandEdges() {
        let edges = BandMath.bandEdges()
        XCTAssertEqual(edges.count, 33)
        XCTAssertEqual(edges[0], 100.0, accuracy: 1e-9)
        XCTAssertEqual(edges[32], 20000.0, accuracy: 1e-6)
    }

    func testSliderCurveRoundTrip() {
        XCTAssertEqual(BandMath.sliderToAmp(0), 0.001, accuracy: 1e-9)
        XCTAssertEqual(BandMath.sliderToAmp(1), 1.0, accuracy: 1e-6)
        for v in stride(from: Float(0), through: 1, by: 0.1) {
            XCTAssertEqual(BandMath.ampToSlider(BandMath.sliderToAmp(v)), v, accuracy: 1e-5)
        }
    }

    func testCOLASumIsExactly1_5() {
        let n = DSPConstants.fftSize
        let hop = DSPConstants.hop
        let w = Windows.periodicHann(n)
        var acc = [Double](repeating: 0, count: n)
        for shift in stride(from: 0, to: n, by: hop) {
            for i in 0..<n {
                let wi = Double(w[(i + shift) % n])
                acc[i] += wi * wi
            }
        }
        for v in acc {
            XCTAssertEqual(v, Double(DSPConstants.colaSum), accuracy: 1e-6)
        }
    }

    func testFFTRoundTrip() {
        let n = DSPConstants.fftSize
        let fft = PureSwiftFFT(size: n)
        var noise = WhiteNoise(seed: 42)
        var input = [Float](repeating: 0, count: n)
        noise.fill(&input, count: n)
        var re = [Float](repeating: 0, count: n / 2 + 1)
        var im = [Float](repeating: 0, count: n / 2 + 1)
        var output = [Float](repeating: 0, count: n)
        fft.forward(input, re: &re, im: &im)
        fft.inverse(re: re, im: im, into: &output)
        for i in 0..<n {
            XCTAssertEqual(output[i], input[i], accuracy: 1e-4)
        }
    }

    /// Unity gain through the full windowed STFT-OLA chain reconstructs the input.
    func testIdentityReconstruction() {
        let n = DSPConstants.fftSize
        let hop = DSPConstants.hop
        let fft = PureSwiftFFT(size: n)
        let w = Windows.periodicHann(n)
        var noise = WhiteNoise(seed: 7)
        let total = 6 * n
        var x = [Float](repeating: 0, count: total)
        noise.fill(&x, count: total)

        var y = [Float](repeating: 0, count: total)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2 + 1)
        var im = [Float](repeating: 0, count: n / 2 + 1)
        var synth = [Float](repeating: 0, count: n)
        var start = 0
        while start + n <= total {
            for i in 0..<n { frame[i] = x[start + i] * w[i] }
            fft.forward(frame, re: &re, im: &im)
            fft.inverse(re: re, im: im, into: &synth)
            for i in 0..<n { y[start + i] += synth[i] * w[i] }
            start += hop
        }
        for i in n..<(total - n) {
            XCTAssertEqual(y[i] / DSPConstants.colaSum, x[i], accuracy: 1e-4)
        }
    }

    func testGainNormalizationInvariant() {
        let bmap = BandMath.bandOfBin(sampleRate: TestSupport.sampleRate,
                                      fftSize: DSPConstants.fftSize)
        let expected = Float(bmap.filter { $0 >= 0 }.count)
        for amps in [Presets.white(), Presets.pink(), Presets.brown(), Presets.blue()] {
            let gain = GainLUT.build(bandAmps: amps, sampleRate: TestSupport.sampleRate)
            let total = gain.reduce(Float(0)) { $0 + $1 * $1 }
            XCTAssertEqual(total / expected, 1.0, accuracy: 1e-3)
        }
    }

    func testAllZeroSpectrumYieldsSilenceNotNaN() {
        let gain = GainLUT.build(bandAmps: [Float](repeating: 0, count: 32),
                                 sampleRate: TestSupport.sampleRate)
        XCTAssertTrue(gain.allSatisfy { $0 == 0 && !$0.isNaN })
    }

    func testLegacyPeriodMapping() {
        XCTAssertEqual(Phonon.legacyPeriodSeconds(slot: 0), 0.010, accuracy: 1e-6)
        XCTAssertEqual(Phonon.legacyPeriodSeconds(slot: 18), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Phonon.legacyPeriodSeconds(slot: 53), 60.0, accuracy: 1e-6)
    }
}
