import SwiftUI

/// Bottom bar: what's playing, for how long, the sleep timer, and Play/Pause.
/// The clocks are system timer texts — SwiftUI updates them only while on
/// screen, so they cost nothing in the background or with the display off.
struct NowPlayingBar: View {
    let model: PlayerModel

    private static let timerChoices = [5, 15, 30, 60, 90]

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.headline)
                    Group {
                        if let started = model.playStartedAt {
                            Text("Playing \(Text(started, style: .timer))")
                        } else {
                            Text("Paused")
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Spacer()

                sleepTimerMenu
            }

            Button(action: model.togglePlayback) {
                Label(model.isPlaying ? "Pause" : "Play",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var sleepTimerMenu: some View {
        Menu {
            Picker("Sleep Timer", selection: timerSelection) {
                Text("Off").tag(Int?.none)
                ForEach(Self.timerChoices, id: \.self) { minutes in
                    Text("\(minutes) min").tag(Int?.some(minutes))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                if let end = model.sleepTimerEnd {
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        .monospacedDigit()
                } else {
                    Text("Sleep")
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(model.sleepTimerEnd.map {
            "Ends at \($0.formatted(date: .omitted, time: .shortened))"
        } ?? "Off")
    }

    private var timerSelection: Binding<Int?> {
        Binding(get: { model.sleepTimerMinutes },
                set: { model.setSleepTimer(minutes: $0) })
    }
}
