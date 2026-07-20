import Foundation

/// Built-in spectra, stored as post-curve amplitudes relative to band 0.
/// Slopes are in power: pink −3 dB/oct → amp ∝ 1/√f, brown −6 dB/oct → amp ∝ 1/f.
public enum Presets {
    public static func white() -> [Float] {
        [Float](repeating: 1.0, count: DSPConstants.bandCount)
    }

    public static func pink() -> [Float] {
        BandMath.bandCenters().map { Float(1.0 / (($0 / DSPConstants.minFrequency).squareRoot())) }
    }

    public static func brown() -> [Float] {
        BandMath.bandCenters().map { Float(DSPConstants.minFrequency / $0) }
    }

    public static func blue() -> [Float] {
        BandMath.bandCenters().map { Float(($0 / DSPConstants.minFrequency).squareRoot()) }
    }

    public static func phonons() -> [Phonon] {
        [
            Phonon(name: "White", amps: white()),
            Phonon(name: "Pink", amps: pink()),
            Phonon(name: "Brown", amps: brown()),
            Phonon(name: "Blue", amps: blue()),
        ]
    }
}
