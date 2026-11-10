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

    /// The platform FFT (vDSP on Apple) must agree with the portable reference
    /// bin for bin, including the DC and Nyquist bins vDSP packs specially.
    func testPlatformFFTMatchesPureSwift() {
        let n = DSPConstants.fftSize
        let reference = PureSwiftFFT(size: n)
        let platform = makeRealFFT(size: n)
        var noise = WhiteNoise(seed: 99)
        var input = [Float](repeating: 0, count: n)
        noise.fill(&input, count: n)
        input[0] += 3   // non-trivial DC
        for i in 0..<n where i % 2 == 0 { input[i] += 0.5 }   // non-trivial Nyquist

        var re1 = [Float](repeating: 0, count: n / 2 + 1), im1 = re1
        var re2 = re1, im2 = re1
        reference.forward(input, re: &re1, im: &im1)
        platform.forward(input, re: &re2, im: &im2)
        // Bins are O(√N · σ) ≈ 40; Float vs Double internals differ ~1e-5 relative.
        for k in 0...(n / 2) {
            XCTAssertEqual(re2[k], re1[k], accuracy: 2e-3, "re[\(k)]")
            XCTAssertEqual(im2[k], im1[k], accuracy: 2e-3, "im[\(k)]")
        }

        var out1 = [Float](repeating: 0, count: n), out2 = out1
        reference.inverse(re: re1, im: im1, into: &out1)
        platform.inverse(re: re1, im: im1, into: &out2)
        for i in 0..<n {
            XCTAssertEqual(out2[i], out1[i], accuracy: 1e-5, "x[\(i)]")
        }
    }

    /// Unity gain through the full windowed STFT-OLA chain reconstructs the
    /// input, with both the reference and the platform FFT.
    func testIdentityReconstruction() {
        identityReconstruction(fft: PureSwiftFFT(size: DSPConstants.fftSize))
        identityReconstruction(fft: makeRealFFT(size: DSPConstants.fftSize))
    }

    private func identityReconstruction(fft: RealFFT) {
        let n = DSPConstants.fftSize
        let hop = DSPConstants.hop
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

    /// Mirrors the reference's "every band has a bin" check: the frame grows
    /// with the output rate, so no band goes silent on a 96 or 192 kHz DAC
    /// (at a fixed 4096, band 1 has no bin at 96 kHz; bands 0, 1, 4 at 192).
    func testEveryBandHasABinAtEveryOutputRate() {
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 16000), 4096)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 44100), 4096)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 48000), 4096)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 88200), 8192)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 96000), 8192)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 176400), 16384)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: 192000), 16384)
        XCTAssertEqual(DSPConstants.fftSize(forSampleRate: .infinity), 65536, "capped")

        for rate in [44100.0, 48000, 88200, 96000, 176400, 192000] {
            let bmap = BandMath.bandOfBin(sampleRate: rate,
                                          fftSize: DSPConstants.fftSize(forSampleRate: rate))
            let missing = (0..<DSPConstants.bandCount).filter { !bmap.contains($0) }
            XCTAssertEqual(missing, [], "bands without a bin at \(rate) Hz")

            // A sound that is only such a band must still make noise.
            var amps = [Float](repeating: 0, count: DSPConstants.bandCount)
            amps[1] = 1
            let gain = GainLUT.build(bandAmps: amps, sampleRate: rate)
            XCTAssertTrue(gain.contains { $0 > 0 }, "band 1 alone is silent at \(rate) Hz")
        }
        let fixed = BandMath.bandOfBin(sampleRate: 96000, fftSize: DSPConstants.fftSize)
        XCTAssertFalse(fixed.contains(1), "the case this guards against")
    }

    /// The streaming path at a doubled frame: unity gain in, stationary
    /// noise at the same level out, a hop at a time.
    func testStreamRunsAtLargerFrameSizes() {
        for rate in [96000.0, 192000] {
            let n = DSPConstants.fftSize(forSampleRate: rate)
            let stream = NoiseStream(seed: 5, fftSize: n)
            XCTAssertEqual(stream.hop, n / 4)
            stream.gain = [Float](repeating: 1, count: n / 2 + 1)
            var hop = [Float](repeating: 0, count: stream.hop)
            var out = [Float]()
            for _ in 0..<12 {
                stream.processHop(into: &hop)
                out.append(contentsOf: hop)
            }
            // Past the first frame, unity gain reconstructs the white noise:
            // uniform in ±1, so RMS 1/√3.
            let steady = out.dropFirst(n)
            let rms = (steady.reduce(Float(0)) { $0 + $1 * $1 } / Float(steady.count)).squareRoot()
            XCTAssertEqual(rms, 1 / Float(3).squareRoot(), accuracy: 0.02, "at \(rate) Hz")
        }
    }

    func testAllZeroSpectrumYieldsSilenceNotNaN() {
        let gain = GainLUT.build(bandAmps: [Float](repeating: 0, count: 32),
                                 sampleRate: TestSupport.sampleRate)
        XCTAssertTrue(gain.allSatisfy { $0 == 0 && !$0.isNaN })
    }

    /// Decoding skips `Phonon.init`'s band-count check; `isPlayable` is the
    /// gate for decoded phonons.
    func testIsPlayableRejectsMalformedDecodedPhonons() throws {
        XCTAssertTrue(Phonon(name: "ok", amps: Presets.pink()).isPlayable)

        func decoded(amps: String) throws -> Phonon {
            let json = #"{"name":"x","amps":\#(amps),"masterVolume":0.7,"#
                + #""tremoloPeriodSeconds":1,"tremoloDepth":0}"#
            return try JSONDecoder().decode(Phonon.self, from: Data(json.utf8))
        }
        XCTAssertFalse(try decoded(amps: "[1,1,1]").isPlayable, "wrong band count")
        let negative = "[" + (["-1"] + [String](repeating: "1", count: 31)).joined(separator: ",") + "]"
        XCTAssertFalse(try decoded(amps: negative).isPlayable, "negative band")

        var infinite = Phonon(name: "inf", amps: Presets.white())
        infinite.amps[3] = .infinity
        XCTAssertFalse(infinite.isPlayable, "non-finite band")
    }

    func testLegacyPeriodMapping() {
        XCTAssertEqual(Phonon.legacyPeriodSeconds(slot: 0), 0.010, accuracy: 1e-6)
        XCTAssertEqual(Phonon.legacyPeriodSeconds(slot: 18), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Phonon.legacyPeriodSeconds(slot: 53), 60.0, accuracy: 1e-6)
    }
}
