import ChromaNoiseKit

/// What `PlayerModel` needs from whatever plays the audio: transport and
/// sound parameters. `StandaloneAudioHost` is the real one; tests drive the
/// model through a host with no audio stack behind it.
@MainActor
protocol AudioHost: AnyObject {
    /// Called on the main actor after every transport state change, whether
    /// requested (play, pause) or not (interruption, route change).
    var onStateChange: ((TransportMachine.State) -> Void)? { get set }

    /// Registers a start synchronously and returns it to await; the task
    /// throws `CancellationError` if something superseded the start.
    func requestStart() -> Task<Void, Error>
    /// Stop rendering but keep the audio session.
    func pause()
    /// Stop rendering and release the audio session.
    func stop()

    func apply(_ phonon: Phonon)
    func setMasterVolume(_ volume: Float)
}
