import Foundation

/// Core constants and band geometry. Verified against tools/reference_dsp.py —
/// if the two disagree, the Python reference wins until proven otherwise.
public enum DSPConstants {
    /// STFT frame size.
    public static let fftSize = 4096
    /// Hop between frames. Hann×Hann COLA requires hop ≤ fftSize/4.
    public static let hop = 1024
    /// Σ of squared periodic-Hann shifts at hop = N/4.
    public static let colaSum: Float = 1.5
    public static let bandCount = 32
    public static let minFrequency = 100.0
    public static let maxFrequency = 20000.0
    /// Welch analysis frame size for the clone feature.
    public static let welchSize = 16384
}

public enum BandMath {
    /// 33 log-spaced band edges: edge[i] = 100 · 200^(i/32); edge[0] = 100 Hz, edge[32] = 20 kHz.
    public static func bandEdges() -> [Double] {
        let ratio = DSPConstants.maxFrequency / DSPConstants.minFrequency
        return (0...DSPConstants.bandCount).map {
            DSPConstants.minFrequency * pow(ratio, Double($0) / Double(DSPConstants.bandCount))
        }
    }

    /// Geometric center frequency of each band.
    public static func bandCenters() -> [Double] {
        let e = bandEdges()
        return (0..<DSPConstants.bandCount).map { sqrt(e[$0] * e[$0 + 1]) }
    }

    /// Map each rfft bin (0...n/2) to a band index, or -1 if outside 100 Hz–20 kHz.
    public static func bandOfBin(sampleRate: Double, fftSize n: Int) -> [Int] {
        let edges = bandEdges()
        return (0...(n / 2)).map { k in
            let f = Double(k) * sampleRate / Double(n)
            guard f >= edges[0], f < edges[DSPConstants.bandCount] else { return -1 }
            // Closed-form log gives the index; edge comparison corrects fp rounding
            // so the mapping matches the reference's explicit range test exactly.
            var idx = min(max(Int(floor(log(f / edges[0]) / log(edges[1] / edges[0]))), 0),
                          DSPConstants.bandCount - 1)
            if f < edges[idx] { idx -= 1 } else if f >= edges[idx + 1] { idx += 1 }
            return min(max(idx, 0), DSPConstants.bandCount - 1)
        }
    }

    /// Slider position v ∈ [0,1] → linear amplitude over a 60 dB range: 0.001·1000^v.
    public static func sliderToAmp(_ v: Float) -> Float {
        0.001 * pow(1000.0, v)
    }

    /// Inverse of sliderToAmp relative to a reference amplitude, clamped to [0,1].
    public static func ampToSlider(_ a: Float, ref: Float = 1.0) -> Float {
        guard a > 0, ref > 0 else { return 0 }
        let v = (log10(a / ref) + 3.0) / 3.0
        return min(max(v, 0), 1)
    }
}
