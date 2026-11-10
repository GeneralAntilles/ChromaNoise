import ChromaNoiseKit
import Foundation
import Testing
@testable import ChromaNoise

/// An `AudioHost` with no audio stack: records what the model asked for and
/// publishes whatever transport state the test sets.
@MainActor
final class FakeAudioHost: AudioHost {
    enum Call: Equatable { case start, pause, stop }

    var onStateChange: ((TransportMachine.State) -> Void)?
    private(set) var calls: [Call] = []
    private(set) var volumes: [Float] = []
    private(set) var applied: [Phonon] = []
    /// Starts to hand out, in order. With none queued, a start succeeds at
    /// once and the transport runs.
    var scriptedStarts: [Task<Void, Error>] = []

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    /// Publish a transport state, as the real host does on every change.
    func set(_ state: TransportMachine.State) {
        onStateChange?(state)
    }

    func requestStart() -> Task<Void, Error> {
        calls.append(.start)
        if !scriptedStarts.isEmpty { return scriptedStarts.removeFirst() }
        set(.running)
        return Task {}
    }

    func pause() {
        calls.append(.pause)
        set(.idle)
    }

    func stop() {
        calls.append(.stop)
        set(.idle)
    }

    func apply(_ phonon: Phonon) { applied.append(phonon) }
    func setMasterVolume(_ volume: Float) { volumes.append(volume) }
}

/// A start the test finishes by hand.
@MainActor
final class StartGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    lazy var task: Task<Void, Error> = Task { @MainActor in
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func finish(_ result: Result<Void, Error> = .success(())) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// A clock that only moves when the test advances it.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant()
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    /// Tasks currently asleep on this clock.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Decided under the lock, so a cancellation or an advance
                // either sees the sleeper or is seen here.
                let outcome: Result<Void, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Move time forward, waking every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Lets other main-actor work run until `ready`, failing instead of hanging.
@MainActor
func waitFor(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
             _ ready: () -> Bool) async {
    for _ in 0..<2000 {
        if ready() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
}

/// A scratch defaults suite, removed when the test's value goes away.
final class ScratchDefaults {
    let name = "ChromaNoiseTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
