import XCTest
@testable import ChromaNoiseKit

/// Mirrors tools/reference_dsp.py checks 10–13: the clone pipeline analyzed
/// against our own synthesis. Ship-blockers for the clone feature.
final class CloneRoundTripTests: XCTestCase {

    private func clone(_ samples: [Float]) throws -> [Float] {
        let result = try WelchAnalyzer.analyze(samples: samples, sampleRate: TestSupport.sampleRate)
        let amps = BandAggregator.bandAmplitudes(psd: result.psd, sampleRate: result.sampleRate)
        return CloneNormalizer.sliders(bandAmplitudes: amps)
    }

    func testCloneOfWhiteIsFlatAt0_85() throws {
        let v = try clone(TestSupport.synthesize(bandAmps: Presets.white(), seconds: 12))
        for (i, s) in v.enumerated() {
            XCTAssertEqual(s, CloneNormalizer.peakSlider, accuracy: 0.025, "band \(i)")
        }
    }

    func testCloneOfPinkHasExpectedSliderSlope() throws {
        let v = try clone(TestSupport.synthesize(bandAmps: Presets.pink(), seconds: 12))
        let slope = TestSupport.slope(
            x: (0..<v.count).map(Double.init),
            y: v.map(Double.init))
        // Pink: amp halves every 2 octaves → Δv per octave = log10(√2)/3 ≈ 0.0502;
        // 32 bands span log2(200) ≈ 7.64 octaves.
        let octavesPerBand = log2(DSPConstants.maxFrequency / DSPConstants.minFrequency)
            / Double(DSPConstants.bandCount)
        let expected = -0.0502 * octavesPerBand
        XCTAssertEqual(slope, expected, accuracy: 0.01)
    }

    func testToneTriggersFlatnessWarningAndNoiseDoesNot() throws {
        let sr = TestSupport.sampleRate
        let tone = (0..<Int(sr * 5)).map { Float(0.5 * sin(2.0 * .pi * 1000.0 * Double($0) / sr)) }
        let tonePSD = try WelchAnalyzer.analyze(samples: tone, sampleRate: sr).psd
        XCTAssertLessThan(SpectralFlatness.flatness(psd: tonePSD),
                          SpectralFlatness.tonalThreshold)

        var rng = WhiteNoise(seed: 3)
        var noise = [Float](repeating: 0, count: Int(sr * 5))
        rng.fill(&noise, count: noise.count)
        let noisePSD = try WelchAnalyzer.analyze(samples: noise, sampleRate: sr).psd
        XCTAssertGreaterThan(SpectralFlatness.flatness(psd: noisePSD), 0.2)
    }

    func testSilenceIsRejected() {
        let silent = [Float](repeating: 0, count: Int(TestSupport.sampleRate * 5))
        XCTAssertThrowsError(try WelchAnalyzer.analyze(samples: silent,
                                                       sampleRate: TestSupport.sampleRate)) {
            XCTAssertEqual($0 as? WelchAnalyzer.AnalysisError, .noAudibleContent)
        }
    }

    func testShortClipIsRejected() {
        var rng = WhiteNoise(seed: 9)
        var clip = [Float](repeating: 0, count: Int(TestSupport.sampleRate * 1))
        rng.fill(&clip, count: clip.count)
        XCTAssertThrowsError(try WelchAnalyzer.analyze(samples: clip,
                                                       sampleRate: TestSupport.sampleRate)) {
            XCTAssertEqual($0 as? WelchAnalyzer.AnalysisError, .clipTooShort)
        }
    }
}
