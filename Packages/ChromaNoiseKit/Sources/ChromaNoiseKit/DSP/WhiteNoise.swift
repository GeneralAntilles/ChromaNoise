import Foundation

/// Deterministic, allocation-free uniform noise in [-1, 1). SplitMix64 core —
/// statistically ample for audio noise, trivially seedable for tests.
public struct WhiteNoise {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    private mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform Float in [-1, 1).
    public mutating func nextSample() -> Float {
        // 24 high bits → [0,1) with full Float mantissa coverage, then center.
        let u = Float(nextUInt64() >> 40) * (1.0 / 16777216.0)
        return u * 2.0 - 1.0
    }

    public mutating func fill(_ buffer: inout [Float], count: Int, at offset: Int = 0) {
        for i in offset..<(offset + count) {
            buffer[i] = nextSample()
        }
    }
}
