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
    /// Cabin playing with a sleep timer counting down (dark).
    case sleep
    /// Another saved sound, with My Sounds filled out (light).
    case favorites

    static let current: ScreenshotScenario? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshot"), i + 1 < args.count else { return nil }
        return ScreenshotScenario(rawValue: args[i + 1])
    }()

    var colorScheme: ColorScheme {
        switch self {
        case .paint, .favorites: .light
        case .sleep: .dark
        }
    }

    /// Saved sounds shown under My Sounds.
    static let savedSounds: [Phonon] = [
        Phonon(name: "Evening Rain", amps: curve { t in
            0.82 - 0.38 * t + 0.12 * exp(-pow((t - 0.25) / 0.1, 2)) + 0.05 * sin(9 * t)
        }),
        // A low hum with a soft shelf in the upper mids.
        Phonon(name: "Deep Focus", amps: curve { t in
            0.55 + 0.3 * exp(-pow((t - 0.08) / 0.12, 2)) + 0.22 * exp(-pow((t - 0.62) / 0.14, 2)) - 0.35 * t
        }),
        Phonon(name: "Night Drive", amps: curve { t in 0.92 - 0.75 * t }),
        Phonon(name: "Study Hall", amps: curve { t in 0.7 - 0.2 * t }),
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
    func apply(to model: PlayerModel) async {
        model.masterVolume = 0.65
        switch self {
        case .paint, .favorites:
            let saved = (try? StoredPhonon.container.mainContext.fetch(
                FetchDescriptor<StoredPhonon>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            let name = self == .paint ? "Evening Rain" : "Deep Focus"
            if let stored = saved.first(where: { $0.name == name }), let phonon = stored.phonon {
                model.load(phonon, as: .saved(id: stored.id))
            }
        case .sleep:
            if let cabin = model.presets.first(where: { $0.name == "Cabin" }) {
                model.load(cabin, as: .builtIn(name: cabin.name))
            }
        }
        await model.play()
        if self == .sleep { model.setSleepTimer(minutes: 30) }
    }

    /// `date` as the clock would show it if now were 9:41:30, mid-way
    /// through the 9:41 tools/screenshots.sh puts in the status bar, so
    /// "Stops at" agrees (a 30-minute timer reads 10:11).
    static func shownTime(_ date: Date) -> Date {
        guard current != nil,
              let nineFortyOne = Calendar.current.date(bySettingHour: 9, minute: 41, second: 30, of: .now)
        else { return date }
        return date.addingTimeInterval(nineFortyOne.timeIntervalSinceNow)
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
