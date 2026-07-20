import Foundation

public enum CloneNormalizer {
    /// Slider value the loudest band is anchored to (leaves headroom to raise
    /// individual bands afterward).
    public static let peakSlider: Float = 0.85
    /// Bands more than this far below the peak floor to slider 0.
    public static let floorDB: Float = -60.0

    /// Band amplitudes → 32 slider values, peak-anchored. No equal-loudness
    /// compensation: the user picked the sound for how it already sounds, and
    /// their ears applied the loudness contour once already.
    public static func sliders(bandAmplitudes: [Float]) -> [Float] {
        guard let peak = bandAmplitudes.max(), peak > 0 else {
            return [Float](repeating: 0, count: DSPConstants.bandCount)
        }
        let ref = peak / BandMath.sliderToAmp(peakSlider)
        let floor = peak * pow(10.0, floorDB / 20.0)
        return bandAmplitudes.map { a in
            a < floor ? 0 : BandMath.ampToSlider(a, ref: ref)
        }
    }
}
