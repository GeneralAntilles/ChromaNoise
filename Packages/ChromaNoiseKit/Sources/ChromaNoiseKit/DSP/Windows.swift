import Foundation

public enum Windows {
    /// Periodic Hann: w[n] = 0.5·(1 − cos(2πn/N)). The periodic (DFT-even) form
    /// is required for the exact COLA property — the symmetric form is not COLA.
    public static func periodicHann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 * (1.0 - Float(cos(2.0 * Double.pi * Double($0) / Double(n)))) }
    }
}
