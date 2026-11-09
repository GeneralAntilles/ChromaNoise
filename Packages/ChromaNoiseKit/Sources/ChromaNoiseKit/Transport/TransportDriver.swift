/// What a `TransportDriver` drives: the host's audio session and engine.
@MainActor
public protocol TransportBackend: AnyObject {
    /// Configures and activates the audio session. Slow; the driver runs one
    /// session operation at a time, in the order it queued them.
    func activateSession() async -> Result<Void, Error>
    /// Deactivates the session, letting other apps' audio resume.
    func deactivateSession() async
    /// Starts rendering. On failure, leaves the engine stopped.
    func startEngine() throws
    func stopEngine()
}

/// Runs a `TransportMachine` against a `TransportBackend`: performs its
/// effects, feeds results back as events, serializes session operations,
/// and turns each start attempt into a task callers can await.
@MainActor
public final class TransportDriver {
    public weak var backend: (any TransportBackend)?

    /// Called after every state change, requested (play, pause) or not
    /// (interruption, route change), before any awaited start completes.
    /// Calls back into the driver from here are handled after it returns,
    /// so `state` doesn't change during the callback.
    public var onStateChange: ((TransportMachine.State) -> Void)?

    public var state: TransportMachine.State { machine.state }

    private var machine = TransportMachine()
    private var publishedState: TransportMachine.State = .idle
    /// Per start attempt: the task callers await, the machine's verdict, and
    /// the error behind a failure.
    private var startTasks: [Int: Task<Void, Error>] = [:]
    private var startOutcomes: [Int: TransportMachine.StartOutcome] = [:]
    private var startErrors: [Int: Error] = [:]
    /// Every session activation and deactivation runs after the previous
    /// one finishes, so a late activation can't land after a later Stop.
    private var sessionTail: Task<Void, Never>?
    private var isHandling = false
    /// Events that arrived mid-handling, each with what to do once handled.
    private var deferredEvents: [(TransportMachine.Event, (() -> Void)?)] = []

    public init() {}

    // MARK: commands

    /// Registers a start synchronously (so pause, interruptions and route
    /// loss can cancel it from this moment on) and returns it to await.
    /// Concurrent calls share one start. The task throws `CancellationError`
    /// if pause, stop, an interruption or route loss came in while the
    /// session was still activating.
    public func requestStart() -> Task<Void, Error> {
        if isHandling {
            // Called back in, from the backend or the state callback.
            if deferredEvents.isEmpty, state.pendingAttempt != nil || state.isRunning {
                // Play would change nothing now: join what's under way.
                return currentStart()
            }
            // Otherwise wait in line like any other event, so a Stop that
            // follows still wins.
            let ticket = StartTicket()
            deferredEvents.append((.play, { [unowned self] in ticket.bind(currentStart()) }))
            return Task { try await ticket.start().value }
        }
        var start: Task<Void, Error> = Task {}
        // Looked up before publishing: the state callback may pause at once,
        // and the caller must then see this start cancelled, not succeed.
        send(.play) { start = currentStart() }
        return start
    }

    /// Right after a Play: the attempt it started or joined, or nothing to
    /// wait for if already running.
    private func currentStart() -> Task<Void, Error> {
        guard let attempt = state.pendingAttempt else { return Task {} }
        return startTasks[attempt] ?? Task { throw CancellationError() }
    }

    /// The start a deferred Play ends up with, once it's handled.
    private final class StartTicket {
        private var bound: Task<Void, Error>?
        private var waiter: CheckedContinuation<Task<Void, Error>, Never>?

        func bind(_ start: Task<Void, Error>) {
            bound = start
            waiter?.resume(returning: start)
            waiter = nil
        }

        func start() async -> Task<Void, Error> {
            if let bound { return bound }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    public func pause() { send(.pause) }
    public func stop() { send(.stop) }
    public func interruptionBegan() { send(.interruptionBegan) }
    public func interruptionEnded(shouldResume: Bool) { send(.interruptionEnded(shouldResume: shouldResume)) }
    public func outputDeviceLost() { send(.outputDeviceLost) }
    public func configurationChanged() { send(.configurationChanged) }

    /// No start attempt is in flight or awaiting cleanup.
    var isSettled: Bool {
        startTasks.isEmpty && startOutcomes.isEmpty && startErrors.isEmpty
    }

    // MARK: effects

    /// Run to completion: an event arriving while another is being handled
    /// (a backend calling back in, e.g. a route change posted from inside
    /// `startEngine`, or the state callback pausing) waits its turn, in
    /// order, so the machine never sees it between an effect and that
    /// effect's result. Each event's resulting state is published in turn.
    private func send(_ event: TransportMachine.Event, beforePublishing: () -> Void = {}) {
        guard !isHandling else {
            deferredEvents.append((event, nil))
            return
        }
        isHandling = true
        defer { isHandling = false }
        handle(event)
        beforePublishing()
        publish()
        while !deferredEvents.isEmpty {
            let (deferred, handled) = deferredEvents.removeFirst()
            handle(deferred)
            handled?()
            publish()
        }
    }

    private func publish() {
        guard machine.state != publishedState else { return }
        publishedState = machine.state
        onStateChange?(publishedState)
    }

    /// Applies one event. Effects report their results through here
    /// directly, ahead of any deferred event: a result describes the effect
    /// just performed.
    private func handle(_ event: TransportMachine.Event) {
        for effect in machine.handle(event) {
            perform(effect)
        }
    }

    private func perform(_ effect: TransportMachine.Effect) {
        switch effect {
        case .activateSession(let attempt):
            beginActivation(attempt)
        case .deactivateSession:
            _ = enqueueSessionOperation { [weak self] in await self?.backend?.deactivateSession() }
        case .startEngine(let attempt):
            let succeeded: Bool
            do {
                try startEngine()
                succeeded = true
            } catch {
                startErrors[attempt] = error
                succeeded = false
            }
            handle(.engineStartFinished(attempt: attempt, succeeded: succeeded))
        case .stopEngine:
            backend?.stopEngine()
        case .restartEngine:
            // The engine has already stopped itself; rebuild it for the new
            // route or sample rate.
            backend?.stopEngine()
            do { try startEngine() } catch { handle(.engineRestartFailed) }
        case .resolve(let attempt, let outcome):
            startOutcomes[attempt] = outcome
        }
    }

    private func startEngine() throws {
        guard let backend else { throw CancellationError() }
        try backend.startEngine()
    }

    /// Queues the attempt's activation now, in call order, so a later Stop's
    /// deactivation lands after it; the machine decides what the result means.
    private func beginActivation(_ attempt: Int) {
        let activation = enqueueSessionOperation { [weak self] in
            await self?.backend?.activateSession() ?? .failure(CancellationError())
        }
        startTasks[attempt] = Task { [weak self] in
            let result = await activation.value
            guard let self else { throw CancellationError() }
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
            case .failure(let error):
                startErrors[attempt] = error
                succeeded = false
            }
            send(.activationFinished(attempt: attempt, succeeded: succeeded))
            try takeOutcome(attempt)
        }
    }

    /// The machine resolves every attempt while handling its activation
    /// result, so by now the outcome is known.
    private func takeOutcome(_ attempt: Int) throws {
        startTasks[attempt] = nil
        let error = startErrors.removeValue(forKey: attempt)
        switch startOutcomes.removeValue(forKey: attempt) {
        case .started:
            return
        case .failed:
            throw error ?? CancellationError()   // every failure records its error
        case .cancelled, nil:
            throw CancellationError()
        }
    }

    /// Queues `operation` behind every session operation queued so far.
    /// Synchronous, so queue order is call order.
    private func enqueueSessionOperation<T>(
        _ operation: @escaping @MainActor () async -> T
    ) -> Task<T, Never> {
        let previous = sessionTail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        sessionTail = Task { _ = await task.value }
        return task
    }
}
