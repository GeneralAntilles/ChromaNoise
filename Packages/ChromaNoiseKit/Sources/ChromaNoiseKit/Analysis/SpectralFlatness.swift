import Foundation

public enum SpectralFlatness {
    /// Warn below this: the source is tonal and cloning captures only timbre.
    public static let tonalThreshold: Float = 0.05

    /// Wiener entropy: geometric mean / arithmetic mean of power bins.
    /// ~1 for white noise, →0 for pure tones.
    public static func flatness(psd: [Float]) -> Float {
        var logSum: Double = 0
        var sum: Double = 0
        var count = 0
        for p in psd where p > 0 {
            logSum += log(Double(p))
            sum += Double(p)
            count += 1
        }
        guard count > 0, sum > 0 else { return 0 }
        return Float(exp(logSum / Double(count)) / (sum / Double(count)))
    }
}
