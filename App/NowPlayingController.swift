import MediaPlayer
import UIKit

/// Lock screen, Control Center and headphone-button integration. Requires
/// the host's non-mixable `.playback` session (a mixable session can never
/// become the Now Playing app). Noise is endless, so the item is published
/// as a live stream: no duration, no scrubber, and seek/skip are disabled.
@MainActor
final class NowPlayingController {
    private var published: (title: String, isPlaying: Bool)?
    private var artwork: MPMediaItemArtwork?
    private var artworkAmps: [Float]?
    private var artworkTask: Task<Void, Never>?
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
        publish()
    }

    /// Redraw the artwork from the sound's bars. The first one renders at
    /// once; later ones wait until painting pauses, so a drag doesn't
    /// re-render and re-publish dozens of times a second.
    func updateArtwork(amps: [Float]) {
        guard amps != artworkAmps else { return }
        artworkAmps = amps
        artworkTask?.cancel()
        guard artwork != nil else {
            renderArtwork(amps)
            return
        }
        artworkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.renderArtwork(amps)
        }
    }

    private func renderArtwork(_ amps: [Float]) {
        guard let image = SpectrumArtwork.image(amps: amps) else { return }
        // The handler may run on any thread and must return the requested
        // size; UIGraphicsImageRenderer is safe off the main thread.
        artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
            guard size != image.size, size.width > 0, size.height > 0 else { return image }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        publish()
    }

    private func publish() {
        guard let published else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: published.title,
            MPMediaItemPropertyArtist: "ChromaNoise",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: published.isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
