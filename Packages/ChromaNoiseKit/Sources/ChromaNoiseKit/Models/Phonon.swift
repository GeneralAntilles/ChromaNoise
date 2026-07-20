import Foundation

/// A saved noise preset: the complete recipe for one sound.
public struct Phonon: Codable, Hashable, Sendable {
    public var name: String
    /// 32 post-curve band amplitudes (not slider positions).
    public var amps: [Float]
    public var masterVolume: Float
    /// Tremolo LFO period; the modulation cycles between (1 − depth) and 1.
    public var tremoloPeriodSeconds: Float
    /// 0 = off. Equivalent to ChromaDoze's (1 − minVol).
    public var tremoloDepth: Float

    public init(
        name: String,
        amps: [Float],
        masterVolume: Float = 0.7,
        tremoloPeriodSeconds: Float = 1.0,
        tremoloDepth: Float = 0.0
    ) {
        precondition(amps.count == DSPConstants.bandCount)
        self.name = name
        self.amps = amps
        self.masterVolume = masterVolume
        self.tremoloPeriodSeconds = tremoloPeriodSeconds
        self.tremoloDepth = tremoloDepth
    }

    /// Convert a legacy ChromaDoze period slider slot (0–53) to seconds,
    /// for importing upstream preset JSON. Piecewise mapping per upstream.
    public static func legacyPeriodSeconds(slot: Int) -> Float {
        let p = min(max(slot, 0), 53)
        switch p {
        case 0...8: return Float(p + 1) * 0.010          // 10–90 ms
        case 9...17: return Float(p - 9 + 1) * 0.100     // 100–900 ms
        case 18...35: return Float(p - 18 + 2) * 0.5     // 1.0–9.5 s
        case 36...44: return Float(p - 36 + 10) * 1.0    // 10–18 s
        default: return Float(p - 45 + 4) * 5.0          // 20–60 s
        }
    }
}
