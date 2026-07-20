import Foundation

/// Sine LFO amplitude modulation between (1 − depth) and 1.0.
/// Matches ChromaDoze's period/minVol tremolo (depth = 1 − minVol);
/// bypassed when depth or period is below 1e-3.
public struct Tremolo {
    public var periodSeconds: Float
    public var depth: Float
    private var phase: Double = 0

    public init(periodSeconds: Float = 1.0, depth: Float = 0.0) {
        self.periodSeconds = periodSeconds
        self.depth = depth
    }

    public var isActive: Bool {
        depth >= 1e-3 && periodSeconds >= 1e-3
    }

    /// Write the envelope into `envelope[0..<count]`, advancing phase. The
    /// caller multiplies it into however many channels share the modulation.
    public mutating func fillEnvelope(into envelope: inout [Float], count: Int, sampleRate: Double) {
        guard isActive else {
            for i in 0..<count { envelope[i] = 1 }
            return
        }
        let inc = 2.0 * Double.pi / (Double(periodSeconds) * sampleRate)
        let base = 1.0 - depth
        for i in 0..<count {
            envelope[i] = base + depth * Float(0.5 + 0.5 * sin(phase))
            phase += inc
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }
    }
}
