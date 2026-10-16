import Foundation
import ChromaNoiseKit

/// Shared helpers. NOTE: the synthesis tests run ~1000 pure-Swift FFTs; run
/// `swift test -c release` — debug builds are 10–30× slower.
enum TestSupport {
    static let sampleRate = 48000.0

    /// Offline synthesis through the real streaming path: build a gain LUT from
    /// band amps, run NoiseStream hop by hop, concatenate.
    static func synthesize(bandAmps: [Float], seconds: Double, seed: UInt64 = 1) -> [Float] {
        let stream = NoiseStream(seed: seed)
        stream.gain = GainLUT.build(bandAmps: bandAmps, sampleRate: sampleRate)
        let hops = Int(seconds * sampleRate) / DSPConstants.hop + 8
        var hopBuf = [Float](repeating: 0, count: DSPConstants.hop)
        var out = [Float]()
        out.reserveCapacity(hops * DSPConstants.hop)
        for _ in 0..<hops {
            stream.processHop(into: &hopBuf)
            out.append(contentsOf: hopBuf)
        }
        // Discard warmup (first full frame) like the reference does.
        return Array(out.dropFirst(DSPConstants.fftSize))
    }

    /// Least-squares slope of y over x.
    static func slope(x: [Double], y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<x.count {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        return num / den
    }

    /// Fitted PSD slope in dB per decade over [fLo, fHi].
    static func psdSlopeDBPerDecade(psd: [Float], sampleRate: Double, fLo: Double, fHi: Double) -> Double {
        let n = (psd.count - 1) * 2
        var xs = [Double]()
        var ys = [Double]()
        for k in 1..<psd.count {
            let f = Double(k) * sampleRate / Double(n)
            if f >= fLo && f <= fHi && psd[k] > 0 {
                xs.append(log10(f))
                ys.append(10.0 * log10(Double(psd[k])))
            }
        }
        return slope(x: xs, y: ys)
    }
}
