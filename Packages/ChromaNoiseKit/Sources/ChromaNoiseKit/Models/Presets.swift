import Foundation

/// Built-in spectra, stored as post-curve amplitudes (unnormalized; the app
/// scales to peak = 1 and the engine normalizes power, so only shape matters).
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

    /// +6 dB/oct power → amp ∝ f.
    public static func violet() -> [Float] {
        BandMath.bandCenters().map { Float($0 / DSPConstants.minFrequency) }
    }

    /// Inverse A-weighting: roughly equal perceived loudness across the band
    /// (boosted lows and extreme highs, where hearing is least sensitive).
    public static func grey() -> [Float] {
        BandMath.bandCenters().map { f in
            let f2 = f * f
            let ra = 12194.0 * 12194.0 * f2 * f2 / (
                (f2 + 20.6 * 20.6)
                    * ((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)).squareRoot()
                    * (f2 + 12194.0 * 12194.0))
            return Float(1 / ra)
        }
    }

    // Sound-alikes: a base slope plus bumps/roll-offs, in dB over log2(f).
    // Starting points tuned by reasoning, not yet by ear.

    /// Surf: between pink and brown, soft top end, slow 9 s swell.
    public static func ocean() -> [Float] {
        shaped { f in -4.5 * octaves(f, 100) - rolloff(above: 4000, f) }
    }

    /// Steady rain: near-white hiss with a 5 kHz sheen and thinned lows.
    public static func rain() -> [Float] {
        shaped { f in -1.5 * octaves(f, 100) + bell(f, center: 5000, width: 1.0, db: 5) - rolloff(below: 400, f) }
    }

    /// Box fan: pink with a low-mid hum and a dull top.
    public static func fan() -> [Float] {
        shaped { f in -3 * octaves(f, 100) + bell(f, center: 250, width: 0.8, db: 6) - rolloff(above: 3000, f) }
    }

    /// Airplane cabin: brown rumble with a 400 Hz drone, little treble.
    public static func cabin() -> [Float] {
        shaped { f in -6 * octaves(f, 100) + bell(f, center: 400, width: 1.0, db: 5) - rolloff(above: 1500, f) }
    }

    public static func phonons() -> [Phonon] {
        [
            Phonon(name: "White", amps: white()),
            Phonon(name: "Pink", amps: pink()),
            Phonon(name: "Brown", amps: brown()),
            Phonon(name: "Blue", amps: blue()),
            Phonon(name: "Violet", amps: violet()),
            Phonon(name: "Grey", amps: grey()),
            Phonon(name: "Ocean", amps: ocean(), tremoloPeriodSeconds: 9, tremoloDepth: 0.6),
            Phonon(name: "Rain", amps: rain()),
            Phonon(name: "Fan", amps: fan()),
            Phonon(name: "Cabin", amps: cabin()),
        ]
    }

    // MARK: shaping helpers

    private static func shaped(_ db: (Double) -> Double) -> [Float] {
        BandMath.bandCenters().map { Float(pow(10, db($0) / 20)) }
    }

    private static func octaves(_ f: Double, _ ref: Double) -> Double { log2(f / ref) }

    /// Gaussian bump over log-frequency; `width` is the std-dev in octaves.
    private static func bell(_ f: Double, center: Double, width: Double, db: Double) -> Double {
        let x = octaves(f, center) / width
        return db * exp(-0.5 * x * x)
    }

    /// Extra −6 dB/oct beyond a corner (0 on the passband side).
    private static func rolloff(above corner: Double, _ f: Double) -> Double {
        max(0, 6 * octaves(f, corner))
    }

    private static func rolloff(below corner: Double, _ f: Double) -> Double {
        max(0, 6 * octaves(corner, f))
    }
}
