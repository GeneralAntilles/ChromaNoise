import Foundation

/// Welch's method PSD estimator for the clone feature: N=16384, periodic Hann,
/// 50% hop, mean of |X|²/windowPower across frames. 50% (not 75%) is right for
/// estimation — we want statistical independence between frames, not COLA.
public enum WelchAnalyzer {
    public struct Result {
        /// welchSize/2 + 1 power bins at the source file's sample rate.
        public let psd: [Float]
        public let sampleRate: Double
        public let frameCount: Int
    }

    public enum AnalysisError: Error, Equatable {
        case clipTooShort
        case noAudibleContent
    }

    /// Minimum non-silent duration; below this the PSD variance is too high.
    public static let minimumSeconds = 3.0
    /// RMS gate for "there is actually audio here."
    public static let silenceFloorDB: Float = -60.0

    public static func analyze(samples: [Float], sampleRate: Double) throws -> Result {
        let n = DSPConstants.welchSize
        let hop = n / 2

        var sumSquares: Double = 0
        for s in samples { sumSquares += Double(s) * Double(s) }
        let rms = Float(sqrt(sumSquares / Double(max(samples.count, 1))))
        guard rms > pow(10.0, silenceFloorDB / 20.0) else {
            throw AnalysisError.noAudibleContent
        }
        guard Double(samples.count) / sampleRate >= minimumSeconds, samples.count >= 2 * n else {
            throw AnalysisError.clipTooShort
        }

        let window = Windows.periodicHann(n)
        var windowPower: Double = 0
        for w in window { windowPower += Double(w) * Double(w) }

        let fft = PureSwiftFFT(size: n)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2 + 1)
        var im = [Float](repeating: 0, count: n / 2 + 1)
        var acc = [Double](repeating: 0, count: n / 2 + 1)
        var frames = 0

        var start = 0
        while start + n <= samples.count {
            for i in 0..<n { frame[i] = samples[start + i] * window[i] }
            fft.forward(frame, re: &re, im: &im)
            for k in 0...(n / 2) {
                acc[k] += (Double(re[k]) * Double(re[k]) + Double(im[k]) * Double(im[k])) / windowPower
            }
            frames += 1
            start += hop
        }
        guard frames >= 2 else { throw AnalysisError.clipTooShort }

        let psd = acc.map { Float($0 / Double(frames)) }
        return Result(psd: psd, sampleRate: sampleRate, frameCount: frames)
    }
}
