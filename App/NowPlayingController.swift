import MediaPlayer

/// Lock screen, Control Center and headphone-button integration. Requires
/// the host's non-mixable `.playback` session (a mixable session can never
/// become the Now Playing app). Noise is endless, so the item is published
/// as a live stream: no duration, no scrubber, and seek/skip are disabled.
@MainActor
final class NowPlayingController {
    private var published: (title: String, isPlaying: Bool)?
    /// Registered handlers, removed on deinit (the command center is a
    /// process-wide singleton and would otherwise keep stale targets).
    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    /// Each action returns whether it succeeded, which is reported back to
    /// the system as the command's status.
    init(play: @escaping @MainActor () -> Bool,
         pause: @escaping @MainActor () -> Bool,
         stop: @escaping @MainActor () -> Bool,
         toggle: @escaping @MainActor () -> Bool) {
        let center = MPRemoteCommandCenter.shared()

        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Bool) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                // Run synchronously so the status reflects the outcome.
                // Handlers normally arrive on the main thread.
                let succeeded = Thread.isMainThread
                    ? MainActor.assumeIsolated { action() }
                    : DispatchQueue.main.sync { MainActor.assumeIsolated { action() } }
                return succeeded ? .success : .commandFailed
            }
            targets.append((command, target))
        }
        handle(center.playCommand, play)
        handle(center.pauseCommand, pause)
        handle(center.stopCommand, stop)
        handle(center.togglePlayPauseCommand, toggle)

        for command in [center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand,
                        center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
                        center.changeRepeatModeCommand, center.changeShuffleModeCommand] {
            command.isEnabled = false
        }
    }

    deinit {
        for (command, target) in targets { command.removeTarget(target) }
    }

    /// Cheap to call often: only publishes when something visible changed.
    func update(title: String, isPlaying: Bool) {
        if let published, published.title == title, published.isPlaying == isPlaying { return }
        published = (title, isPlaying)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "ChromaNoise",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
