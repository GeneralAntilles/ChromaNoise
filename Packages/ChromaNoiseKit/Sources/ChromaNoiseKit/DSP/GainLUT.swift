import Foundation

public enum GainLUT {
    /// Per-rfft-bin gain from 32 post-curve band amplitudes.
    ///
    /// Flat fill within each band. Constant-power normalization rescales so
    /// Σ gain² over active bins equals the active-bin count — an all-ones
    /// spectrum is the unit gain, and repainting the spectrum never changes
    /// overall loudness (master volume is the only level control).
    public static func build(
        bandAmps: [Float],
        sampleRate: Double,
        fftSize n: Int = DSPConstants.fftSize,
        normalize: Bool = true
    ) -> [Float] {
        precondition(bandAmps.count == DSPConstants.bandCount)
        let bmap = BandMath.bandOfBin(sampleRate: sampleRate, fftSize: n)
        var gain = [Float](repeating: 0, count: n / 2 + 1)
        var activeBins = 0
        for k in 0...(n / 2) where bmap[k] >= 0 {
            gain[k] = bandAmps[bmap[k]]
            activeBins += 1
        }
        if normalize {
            var power: Float = 0
            for g in gain { power += g * g }
            if power > 1e-12 {
                let scale = sqrt(Float(activeBins) / power)
                for k in 0..<gain.count { gain[k] *= scale }
            } else {
                // All-silent spectrum: leave gain at zero (silence, not NaN).
                for k in 0..<gain.count { gain[k] = 0 }
            }
        }
        return gain
    }
}
