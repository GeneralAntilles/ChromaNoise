#if DEBUG
import ChromaNoiseKit
import SwiftData
import SwiftUI

/// Debug-only staged scenes for App Store screenshots, chosen with the launch
/// argument `-screenshot <scene>` (see tools/screenshots.sh). A scene runs
/// on an in-memory store with seeded saved sounds, ignores and never writes
/// the user's last sound, and mutes audio output while the UI shows playback.
enum ScreenshotScenario: String {
    /// A painted saved sound, playing (light).
    case paint
    /// Ocean playing with the swell section in view (dark).
    case swell
    /// Brown playing with a sleep timer running (dark).
    case sleep
    /// Landscape painter (light); the UI test rotates the device.
    case landscape

    static let current: ScreenshotScenario? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshot"), i + 1 < args.count else { return nil }
        return ScreenshotScenario(rawValue: args[i + 1])
    }()

    var colorScheme: ColorScheme {
        switch self {
        case .paint, .landscape: .light
        case .swell, .sleep: .dark
        }
    }

    /// Saved sounds shown under My Sounds.
    static let savedSounds: [Phonon] = [
        Phonon(name: "Evening Rain", amps: curve { t in
            0.82 - 0.38 * t + 0.12 * exp(-pow((t - 0.25) / 0.1, 2)) + 0.05 * sin(9 * t)
        }),
        Phonon(name: "Deep Focus", amps: curve { t in 0.9 - 0.55 * t }),
    ]

    static func seed(_ context: ModelContext) {
        for phonon in savedSounds {
            if let stored = try? StoredPhonon(phonon: phonon, name: phonon.name) {
                context.insert(stored)
            }
        }
    }

    /// Put the model into this scene's state.
    @MainActor
    func apply(to model: PlayerModel) {
        model.masterVolume = 0.65
        switch self {
        case .paint, .landscape:
            let saved = (try? StoredPhonon.container.mainContext.fetch(
                FetchDescriptor<StoredPhonon>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            if let first = saved.first, let phonon = first.phonon {
                model.load(phonon, as: .saved(id: first.id))
            }
        case .swell:
            if let ocean = model.presets.first(where: { $0.name == "Ocean" }) {
                model.load(ocean, as: .builtIn(name: ocean.name))
            }
        case .sleep:
            if let brown = model.presets.first(where: { $0.name == "Brown" }) {
                model.load(brown, as: .builtIn(name: brown.name))
            }
        }
        model.play()
        if self == .sleep { model.setSleepTimer(minutes: 30) }
    }

    /// 32 band amps from a slider-position curve over t ∈ 0…1.
    private static func curve(_ v: (Double) -> Double) -> [Float] {
        (0..<DSPConstants.bandCount).map { band in
            let t = Double(band) / Double(DSPConstants.bandCount - 1)
            return BandMath.sliderToAmp(Float(min(max(v(t), 0), 1)))
        }
    }
}
#endif
