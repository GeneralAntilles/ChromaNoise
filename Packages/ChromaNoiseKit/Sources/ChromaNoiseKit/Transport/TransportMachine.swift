/// Play/pause policy for a standalone host: what to do about Play, Pause,
/// Stop, interruptions, route loss and engine reconfiguration, and in which
/// order. Pure — the host performs the returned effects (activating the
/// audio session, starting the engine) and reports results back as events,
/// so every race between them can be tested without an audio stack.
///
/// A start is an *attempt*: session activation is slow and asynchronous, so
/// anything that happens meanwhile (pause, stop, an interruption, unplugging)
/// supersedes the attempt. A superseded attempt is cancelled when its
/// activation finishes, and never starts the engine.
public struct TransportMachine: Sendable {
    public enum State: Hashable, Sendable {
        /// Not rendering. (After a pause the session may still be active,
        /// so lock-screen Play keeps routing to us.)
        case idle
        /// Waiting for `attempt`'s session activation. `resuming` marks the
        /// automatic restart after an interruption, which no caller awaits.
        case starting(attempt: Int, resuming: Bool)
        case running
        /// Interrupted while playing: `.interruptionEnded(shouldResume: true)`
        /// restarts us. A Play pressed meanwhile is `pendingAttempt`; only its
        /// success leaves this state, so a failure keeps the resume armed.
        case interrupted(pendingAttempt: Int?)

        public var isRunning: Bool { self == .running }

        /// A start is under way, explicitly or as an interruption's resume.
        public var isStarting: Bool {
            switch self {
            case .starting: true
            case .interrupted(let pending): pending != nil
            case .idle, .running: false
            }
        }

        /// The attempt a new Play joins rather than starting another.
        public var pendingAttempt: Int? {
            switch self {
            case .starting(let attempt, _): attempt
            case .interrupted(let pending): pending
            case .idle, .running: nil
            }
        }
    }

    public enum Event: Hashable, Sendable {
        case play
        /// Stop rendering, keep the session (we stay the Now Playing app).
        case pause
        /// Stop rendering and release the session.
        case stop
        case activationFinished(attempt: Int, succeeded: Bool)
        case engineStartFinished(attempt: Int, succeeded: Bool)
        /// The engine stopped itself for a route or sample-rate change.
        case configurationChanged
        case engineRestartFailed
        /// The system has already silenced us and deactivated the session.
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// Headphones unplugged / Bluetooth gone. Never auto-resumes.
        case outputDeviceLost
    }

    public enum Effect: Hashable, Sendable {
        /// Activate the session asynchronously, queued behind earlier session
        /// operations, then send `.activationFinished`.
        case activateSession(attempt: Int)
        /// Queue a deactivation behind any activation still in flight.
        case deactivateSession
        /// Start the engine now, then send `.engineStartFinished`.
        case startEngine(attempt: Int)
        case stopEngine
        /// Rebuild the engine for the new route; send `.engineRestartFailed`
        /// if that fails.
        case restartEngine
        /// The attempt is over; whoever awaits it gets `outcome`.
        case resolve(attempt: Int, StartOutcome)
    }

    public enum StartOutcome: Hashable, Sendable {
        case started
        case failed
        /// Superseded by a pause, stop, interruption or route loss.
        case cancelled
    }

    public private(set) var state: State = .idle
    private var nextAttempt = 0

    public init() {}

    /// Applies `event` and returns the effects to perform, in order.
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {

        // MARK: play

        case (.idle, .play):
            let attempt = makeAttempt()
            state = .starting(attempt: attempt, resuming: false)
            return [.activateSession(attempt: attempt)]

        case (.interrupted(.none), .play):
            // Pressed during an interruption: try anyway (it usually fails
            // until the interruption ends), keeping the resume armed.
            let attempt = makeAttempt()
            state = .interrupted(pendingAttempt: attempt)
            return [.activateSession(attempt: attempt)]

        case (.starting, .play), (.interrupted(.some), .play), (.running, .play):
            return []   // joins the attempt under way, or already playing

        // MARK: pause / stop — always win, from any state

        case (_, .pause), (_, .stop):
            let wasRunning = state.isRunning
            state = .idle
            return (wasRunning ? [.stopEngine] : [])
                + (event == .stop ? [.deactivateSession] : [])

        // MARK: attempt progress

        case (_, .activationFinished(let attempt, let succeeded)):
            guard attempt == state.pendingAttempt else {
                // Superseded meanwhile: leave the engine off. A stop queued
                // its deactivation behind this activation; a pause keeps the
                // session active, as paused sessions are.
                return [.resolve(attempt: attempt, .cancelled)]
            }
            guard succeeded else { return failAttempt(attempt, deactivating: false) }
            return [.startEngine(attempt: attempt)]

        case (_, .engineStartFinished(let attempt, let succeeded)):
            guard attempt == state.pendingAttempt else { return [] }
            guard succeeded else { return failAttempt(attempt, deactivating: true) }
            state = .running
            return [.resolve(attempt: attempt, .started)]

        // MARK: engine reconfiguration

        case (.running, .configurationChanged):
            return [.restartEngine]
        case (_, .configurationChanged):
            return []   // a start under way reads the new format itself

        case (.running, .engineRestartFailed):
            state = .idle
            return [.deactivateSession]
        case (_, .engineRestartFailed):
            return []

        // MARK: interruptions

        case (.running, .interruptionBegan),
             (.starting(_, resuming: true), .interruptionBegan),
             (.interrupted, .interruptionBegan):
            // Playing, or on the way back to it: stay armed to resume. A Play
            // pressed during an earlier interruption is dropped.
            let wasRunning = state.isRunning
            state = .interrupted(pendingAttempt: nil)
            // Queueing a deactivation although the system has deactivated us
            // undoes any activation still in flight, so we never hold the
            // session through the interruption.
            return (wasRunning ? [.stopEngine] : []) + [.deactivateSession]

        case (.idle, .interruptionBegan), (.starting(_, resuming: false), .interruptionBegan):
            // Only actual playback earns a resume; a start still activating
            // is just dropped (it would fail anyway).
            state = .idle
            return [.deactivateSession]

        case (.interrupted, .interruptionEnded(shouldResume: true)):
            // A Play pressed meanwhile may still be pending (and may fail):
            // resume with a fresh activation instead of sharing its outcome.
            let attempt = makeAttempt()
            state = .starting(attempt: attempt, resuming: true)
            return [.activateSession(attempt: attempt)]

        case (.interrupted(let pending), .interruptionEnded(shouldResume: false)):
            // The system says don't resume (e.g. another app took over), but
            // a Play the user pressed meanwhile still counts.
            state = pending.map { .starting(attempt: $0, resuming: false) } ?? .idle
            return []

        case (_, .interruptionEnded):
            return []   // not interrupted while playing

        // MARK: route loss

        case (.idle, .outputDeviceLost):
            return []
        case (.interrupted(.none), .outputDeviceLost):
            // The system already deactivated us; just disarm the resume.
            state = .idle
            return []
        case (_, .outputDeviceLost):
            // Also drops a pending start or resume: unplugging mid-activation
            // or mid-interruption must not restart us on the speaker.
            let wasRunning = state.isRunning
            state = .idle
            return (wasRunning ? [.stopEngine] : []) + [.deactivateSession]
        }
    }

    private mutating func makeAttempt() -> Int {
        nextAttempt += 1
        return nextAttempt
    }

    /// The current attempt failed. A failed Play during an interruption
    /// leaves the resume armed; any other failure leaves us idle.
    private mutating func failAttempt(_ attempt: Int, deactivating: Bool) -> [Effect] {
        if case .interrupted = state {
            state = .interrupted(pendingAttempt: nil)
        } else {
            state = .idle
        }
        return (deactivating ? [.deactivateSession] : []) + [.resolve(attempt: attempt, .failed)]
    }
}
