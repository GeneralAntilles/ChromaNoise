import XCTest
import ChromaNoiseKit

/// Mirrors tools/reference_dsp.py checks 6–9: spectral shape and stationarity
/// of the streaming synthesis. Run with -c release; these push ~10 s of audio
/// through the pure-Swift FFT.
final class SynthesisTests: XCTestCase {

    func testWhiteIsFlatInBandAndRejectsOutOfBand() throws {
        let out = TestSupport.synthesize(bandAmps: Presets.white(), seconds: 10)
        let psd = try WelchAnalyzer.analyze(samples: out, sampleRate: TestSupport.sampleRate).psd

        // Band-averaged flatness (bin-level p2p is estimator noise).
        let amps = BandAggregator.bandAmplitudes(psd: psd, sampleRate: TestSupport.sampleRate)
        let inner = amps[1..<(DSPConstants.bandCount - 1)]
        let db = inner.map { 20.0 * log10(Double($0)) }
        XCTAssertLessThan(db.max()! - db.min()!, 1.0, "band-averaged p2p over 1 dB")

        // Sub-100 Hz rejection > 40 dB.
        let n = (psd.count - 1) * 2
        var low = 0.0, lowN = 0
        var mid = 0.0, midN = 0
        for k in 1..<psd.count {
            let f = Double(k) * TestSupport.sampleRate / Double(n)
            if f > 10 && f < 80 { low += Double(psd[k]); lowN += 1 }
            if f > 150 && f < 18000 { mid += Double(psd[k]); midN += 1 }
        }
        let leak = 10.0 * log10((low / Double(lowN)) / (mid / Double(midN)))
        XCTAssertLessThan(leak, -40.0)
    }

    func testPinkSlope() throws {
        let out = TestSupport.synthesize(bandAmps: Presets.pink(), seconds: 10)
        let psd = try WelchAnalyzer.analyze(samples: out, sampleRate: TestSupport.sampleRate).psd
        let slope = TestSupport.psdSlopeDBPerDecade(
            psd: psd, sampleRate: TestSupport.sampleRate, fLo: 200, fHi: 10000)
        XCTAssertEqual(slope, -10.0, accuracy: 1.5)
    }

    func testBrownSlope() throws {
        let out = TestSupport.synthesize(bandAmps: Presets.brown(), seconds: 10)
        let psd = try WelchAnalyzer.analyze(samples: out, sampleRate: TestSupport.sampleRate).psd
        let slope = TestSupport.psdSlopeDBPerDecade(
            psd: psd, sampleRate: TestSupport.sampleRate, fLo: 200, fHi: 10000)
        XCTAssertEqual(slope, -20.0, accuracy: 2.0)
    }

    /// Every built-in is a valid 32-band spectrum with a unique name.
    func testBuiltInPresetsAreWellFormed() {
        let presets = Presets.phonons()
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count, "duplicate preset name")
        XCTAssertTrue(Presets.groups().allSatisfy { !$0.phonons.isEmpty }, "empty preset group")
        for p in presets {
            XCTAssertEqual(p.amps.count, DSPConstants.bandCount, p.name)
            XCTAssertTrue(p.amps.allSatisfy { $0.isFinite && $0 > 0 }, "\(p.name) has a non-positive or non-finite band")
        }
    }

    /// No OLA pumping: 100 ms RMS windows vary < 3 dB.
    func testStationarity() {
        let out = TestSupport.synthesize(bandAmps: Presets.white(), seconds: 10)
        let win = Int(0.1 * TestSupport.sampleRate)
        var rmsValues = [Double]()
        var i = 0
        while i + win <= out.count {
            var sum = 0.0
            for j in i..<(i + win) { sum += Double(out[j]) * Double(out[j]) }
            rmsValues.append(sqrt(sum / Double(win)))
            i += win
        }
        let pump = 20.0 * log10(rmsValues.max()! / rmsValues.min()!)
        XCTAssertLessThan(pump, 3.0)
    }
}
