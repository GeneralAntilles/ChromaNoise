import Foundation

public enum BandAggregator {
    /// Collapse a Welch PSD into 32 band amplitudes: mean of bin powers within
    /// the band (mean, not sum — sum would bias toward the wider high bands),
    /// then sqrt to amplitude.
    public static func bandAmplitudes(psd: [Float], sampleRate: Double) -> [Float] {
        let n = (psd.count - 1) * 2
        let bmap = BandMath.bandOfBin(sampleRate: sampleRate, fftSize: n)
        var power = [Double](repeating: 0, count: DSPConstants.bandCount)
        var count = [Int](repeating: 0, count: DSPConstants.bandCount)
        for k in 0..<psd.count where bmap[k] >= 0 {
            power[bmap[k]] += Double(psd[k])
            count[bmap[k]] += 1
        }
        return (0..<DSPConstants.bandCount).map {
            count[$0] > 0 ? Float((power[$0] / Double(count[$0])).squareRoot()) : 0
        }
    }
}
