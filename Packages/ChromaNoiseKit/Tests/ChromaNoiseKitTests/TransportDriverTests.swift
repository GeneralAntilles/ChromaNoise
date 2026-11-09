@testable import ChromaNoiseKit
import Testing

/// Wakes waiters whenever something they may be waiting for changed: no
/// guessing how many yields the scheduler needs.
@MainActor
private final class Changes {
    private struct Waiter {
        let id: Int
        let ready: () -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []
    private var nextID = 0

    /// Returns once `ready` holds. A regression that never makes it hold
    /// fails the test after a few seconds instead of hanging the suite; the
    /// timeout never decides a passing run.
    func wait(until ready: @escaping () -> Bool) async {
        if ready() { return }
        nextID += 1
        let id = nextID
        // Main-actor task, like everything here: no cross-actor races on
        // `waiters`.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.release(id)
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, ready: ready, continuation: continuation))
        }
        timeout.cancel()
        if !ready() { Issue.record("gave up waiting after 5 s") }
    }

    func happened() {
        let done = waiters.filter { $0.ready() }
        waiters.removeAll { $0.ready() }
        done.forEach { $0.continuation.resume() }
    }

    private func release(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

/// A backend whose session activations stay in flight until the test
/// finishes them, so events can land mid-activation as they do on a device.
@MainActor
private final class FakeBackend: TransportBackend {
    enum Call: Equatable {
        case activate
        /// `activateSession` returned to the driver (the fake's own marker).
        case activationReturned
        case deactivate, startEngine, stopEngine
    }
    struct Failure: Error, Equatable { let name: String }

    let changes: Changes
    private(set) var calls: [Call] = [] { didSet { changes.happened() } }
    private(set) var violations: [String] = []
    private(set) var engineRunning = false
    var engineStartError: Failure?
    /// Runs inside `startEngine`, before it succeeds or throws, as a
    /// notification delivered synchronously mid-start would.
    var duringStartEngine: (() -> Void)?
    private var activations: [CheckedContinuation<Result<Void, Error>, Never>] = []

    init(changes: Changes) { self.changes = changes }

    func activateSession() async -> Result<Void, Error> {
        let result = await withCheckedContinuation {
            activations.append($0)
            calls.append(.activate)
        }
        calls.append(.activationReturned)
        return result
    }

    func deactivateSession() async {
        calls.append(.deactivate)
    }

    func startEngine() throws {
        // Kit contract: never prepare while the old engine renders.
        if engineRunning { violations.append("engine started while running") }
        duringStartEngine?()
        if let engineStartError { throw engineStartError }
        engineRunning = true
        calls.append(.startEngine)
    }

    func stopEngine() {
        engineRunning = false
        calls.append(.stopEngine)
    }

    var activationsInFlight: Int { activations.count }

    /// Finishes the oldest activation once the driver has begun it.
    func finishActivation(_ result: Result<Void, Error> = .success(())) async {
        await changes.wait { [unowned self] in !activations.isEmpty }
        guard !activations.isEmpty else { return }   // gave up; already recorded
        activations.removeFirst().resume(returning: result)
    }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
}

private enum Phase: Equatable {
    case idle, starting, running, interrupted

    init(_ state: TransportMachine.State) {
        switch state {
        case .idle: self = .idle
        case .starting: self = .starting
        case .running: self = .running
        case .interrupted: self = .interrupted
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TransportDriverTests {
    private let changes = Changes()
    private let backend: FakeBackend
    private let driver = TransportDriver()
    private let log = Log()

    private final class Log { var phases: [Phase] = [] }

    init() {
        backend = FakeBackend(changes: changes)
        driver.backend = backend
        driver.onStateChange = { [log, changes] in
            log.phases.append(Phase($0))
            changes.happened()
        }
    }

    private func waitFor(_ ready: @escaping () -> Bool) async {
        await changes.wait(until: ready)
    }

    private struct NeverFinished: Error {}
    private final class Outcome { var result: Result<Void, Error>? }

    /// Awaits a start, failing the test (rather than hanging the suite) if
    /// a regression leaves it pending: awaiting an unstructured task's value
    /// ignores the test's cancellation.
    private func value(_ start: Task<Void, Error>?) async throws {
        guard let start else { throw NeverFinished() }
        let outcome = Outcome()
        Task { [changes] in
            outcome.result = await start.result
            changes.happened()
        }
        await waitFor { outcome.result != nil }
        guard let result = outcome.result else { throw NeverFinished() }
        try result.get()
    }

    private func startPlaying() async throws {
        let start = driver.requestStart()
        await backend.finishActivation()
        try await value(start)
    }

    // MARK: starts

    @Test func startPublishesEachChangeOnceBeforeTheAwaiterResumes() async throws {
        try await startPlaying()
        // The engine result is handled within the activation's event; it
        // must not be published twice, and must be out before the caller
        // resumes.
        #expect(log.phases == [.starting, .running])
        #expect(backend.calls == [.activate, .activationReturned, .startEngine])
        #expect(driver.isSettled)
    }

    @Test func concurrentStartsShareOneActivation() async throws {
        let first = driver.requestStart()
        let second = driver.requestStart()
        await backend.finishActivation()
        try await value(first)
        try await value(second)
        #expect(backend.count(.activate) == 1)
        try await value(driver.requestStart())   // already running: no session work
        #expect(backend.count(.activate) == 1)
        // Joining a start or playing while running changes nothing, so
        // nothing is published for it.
        #expect(log.phases == [.starting, .running])
    }

    @Test func activationErrorReachesTheAwaiter() async throws {
        let start = driver.requestStart()
        await backend.finishActivation(.failure(FakeBackend.Failure(name: "busy")))
        await #expect(throws: FakeBackend.Failure(name: "busy")) { try await value(start) }
        #expect(driver.state == .idle)
        #expect(backend.count(.startEngine) == 0)
        #expect(driver.isSettled)
    }

    @Test func activationErrorAfterAPauseStillReachesTheAwaiter() async throws {
        try await startPlaying()
        driver.pause()
        let restart = driver.requestStart()
        await backend.finishActivation(.failure(FakeBackend.Failure(name: "busy")))
        await #expect(throws: FakeBackend.Failure(name: "busy")) { try await value(restart) }
        #expect(driver.state == .idle && !backend.engineRunning)
        // A failed retry doesn't release the session the pause kept.
        #expect(backend.count(.deactivate) == 0)
        #expect(driver.isSettled)
    }

    @Test func engineErrorReachesTheAwaiterAndReleasesTheSession() async throws {
        backend.engineStartError = FakeBackend.Failure(name: "format")
        let start = driver.requestStart()
        await backend.finishActivation()
        await #expect(throws: FakeBackend.Failure(name: "format")) { try await value(start) }
        await waitFor { [backend] in backend.count(.deactivate) == 1 }
        #expect(backend.calls == [.activate, .activationReturned, .deactivate])
        #expect(log.phases == [.starting, .idle])
        #expect(driver.isSettled)
    }

    // MARK: pause / stop

    @Test func pauseDuringActivationCancelsTheStart() async throws {
        let start = driver.requestStart()
        driver.pause()
        await backend.finishActivation()
        await #expect(throws: CancellationError.self) { try await value(start) }
        #expect(backend.count(.startEngine) == 0)
        #expect(driver.state == .idle)
        #expect(driver.isSettled)
    }

    @Test func pauseNeverReleasesTheSession() async throws {
        try await startPlaying()
        driver.pause()
        // Session operations run in order: once the next activation has
        // begun, any deactivation the pause queued would have run.
        let next = driver.requestStart()
        await waitFor { [backend] in backend.count(.activate) == 2 }
        #expect(backend.count(.deactivate) == 0)
        #expect(backend.calls.suffix(2) == [.stopEngine, .activate])
        await backend.finishActivation()
        try await value(next)
    }

    @Test func stopWaitsForAnActivationInFlight() async throws {
        let start = driver.requestStart()
        driver.stop()
        await backend.finishActivation()
        await #expect(throws: CancellationError.self) { try await value(start) }
        await waitFor { [backend] in backend.count(.deactivate) == 1 }
        // Never before the activation it follows has returned.
        #expect(backend.calls == [.activate, .activationReturned, .deactivate])
    }

    @Test func playStopPlayRunsSessionWorkInOrder() async throws {
        let first = driver.requestStart()
        driver.stop()
        let second = driver.requestStart()
        await backend.finishActivation()
        await backend.finishActivation()
        await #expect(throws: CancellationError.self) { try await value(first) }
        try await value(second)
        #expect(backend.calls == [.activate, .activationReturned, .deactivate,
                                  .activate, .activationReturned, .startEngine])
        #expect(driver.state == .running)
    }

    // MARK: system events

    @Test func interruptionResumesWithoutAnAwaiter() async throws {
        try await startPlaying()
        driver.interruptionBegan()
        await waitFor { [backend] in backend.count(.deactivate) == 1 }
        #expect(backend.calls.suffix(2) == [.stopEngine, .deactivate])
        driver.interruptionEnded(shouldResume: true)
        await backend.finishActivation()
        await waitFor { [driver] in driver.state == .running }
        #expect(log.phases == [.starting, .running, .interrupted, .starting, .running])
        await waitFor { [driver] in driver.isSettled }
    }

    @Test func unplugDuringResumeLeavesEverythingStopped() async throws {
        try await startPlaying()
        driver.interruptionBegan()
        driver.interruptionEnded(shouldResume: true)
        driver.outputDeviceLost()
        await backend.finishActivation()
        await waitFor { [backend] in backend.count(.deactivate) == 2 }
        await waitFor { [driver] in driver.isSettled }
        #expect(driver.state == .idle && !backend.engineRunning)
        #expect(backend.count(.startEngine) == 1)
    }

    @Test func routeChangeRestartStopsBeforeStarting() async throws {
        try await startPlaying()
        driver.configurationChanged()
        #expect(backend.calls.suffix(2) == [.stopEngine, .startEngine])
        #expect(driver.state == .running && backend.engineRunning)
        #expect(backend.violations.isEmpty)
    }

    @Test func failedRestartAfterRouteChangePublishesIdle() async throws {
        try await startPlaying()
        backend.engineStartError = FakeBackend.Failure(name: "route")
        driver.configurationChanged()
        await waitFor { [backend] in backend.count(.deactivate) == 1 }
        #expect(driver.state == .idle && !backend.engineRunning)
        #expect(log.phases.last == .idle)
        #expect(backend.calls.suffix(2) == [.stopEngine, .deactivate])
        #expect(backend.activationsInFlight == 0)
    }

    // MARK: reentrancy

    @Test func unplugPostedFromInsideEngineStartStillStopsTheEngine() async throws {
        backend.duringStartEngine = { [driver] in driver.outputDeviceLost() }
        let start = driver.requestStart()
        await backend.finishActivation()
        try await value(start)   // it did start; the unplug came after
        #expect(driver.state == .idle)
        #expect(!backend.engineRunning)
        #expect(log.phases == [.starting, .running, .idle])
    }

    @Test func playThenStopFromInsideEngineStartEndsStopped() async throws {
        var nested: Task<Void, Error>?
        backend.duringStartEngine = { [driver] in
            nested = driver.requestStart()   // joins the start under way
            driver.stop()                    // and the later Stop wins
        }
        try await startPlaying()
        try await value(nested)
        await waitFor { [backend] in backend.count(.deactivate) == 1 }
        #expect(driver.state == .idle && !backend.engineRunning)
        #expect(backend.count(.activate) == 1)
    }

    @Test func stopThenPlayFromInsideEngineStartWaitsForTheNewStart() async throws {
        var nested: Task<Void, Error>?
        backend.duringStartEngine = { [driver, backend] in
            backend.duringStartEngine = nil
            driver.stop()
            nested = driver.requestStart()   // after the Stop: a fresh start
        }
        try await startPlaying()
        await waitFor { [backend] in backend.count(.activate) == 2 }
        #expect(backend.calls == [.activate, .activationReturned, .startEngine, .stopEngine,
                                  .deactivate, .activate])
        // Bound to the new attempt: unresolved while it activates, then
        // exactly its outcome.
        let outcome = Outcome()
        if let nested {
            Task { [changes] in
                outcome.result = await nested.result
                changes.happened()
            }
        }
        await Task.yield()
        #expect(outcome.result == nil)
        await backend.finishActivation(.failure(FakeBackend.Failure(name: "second")))
        await #expect(throws: FakeBackend.Failure(name: "second")) { try await value(nested) }
        #expect(driver.state == .idle && !backend.engineRunning)
    }

    @Test func playFromInsideAFailingEngineStartSharesTheFailure() async throws {
        var nested: Task<Void, Error>?
        backend.engineStartError = FakeBackend.Failure(name: "format")
        backend.duringStartEngine = { [driver] in nested = driver.requestStart() }
        let start = driver.requestStart()
        await backend.finishActivation()
        await #expect(throws: FakeBackend.Failure(name: "format")) { try await value(start) }
        await #expect(throws: FakeBackend.Failure(name: "format")) { try await value(nested) }
        #expect(backend.count(.activate) == 1)   // joined, not retried
    }

    @Test func pauseFromTheStateCallbackCancelsTheStart() async throws {
        driver.onStateChange = { [driver] state in
            if case .starting = state { driver.pause() }
        }
        let start = driver.requestStart()
        await backend.finishActivation()
        await #expect(throws: CancellationError.self) { try await value(start) }
        #expect(driver.state == .idle && !backend.engineRunning)
    }

    @Test func playFromInsideEngineStartWaitsForThatStart() async throws {
        var nested: Task<Void, Error>?
        backend.duringStartEngine = { [driver] in nested = driver.requestStart() }
        try await startPlaying()
        try await value(nested)
        #expect(driver.state == .running)
        #expect(backend.count(.activate) == 1)
    }
}
