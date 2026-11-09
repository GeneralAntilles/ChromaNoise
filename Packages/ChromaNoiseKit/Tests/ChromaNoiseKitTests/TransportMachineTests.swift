import ChromaNoiseKit
import Testing

/// Plays the host's part around a `TransportMachine`: activations finish in
/// the order they were queued (the host serializes session operations) and
/// engine starts are answered at once. Records outcomes and any violation of
/// the transport's safety rules, so tests assert behavior, not effect lists.
private struct Harness {
    typealias M = TransportMachine

    private(set) var machine = M()
    var state: M.State { machine.state }
    /// Engine starts (and restarts) fail while set.
    var engineFails = false

    private(set) var engineOn = false
    /// Session operations run one at a time, in queue order: an activation
    /// holds up everything behind it until it finishes.
    private enum SessionOp: Equatable { case activate(Int), deactivate }
    private var sessionOps: [SessionOp] = []
    /// The session as the operations run so far have left it.
    private(set) var sessionActive = false
    /// Once everything queued has run, the session will be released.
    var sessionEndsReleased: Bool {
        sessionOps.last.map { $0 == .deactivate } ?? !sessionActive
    }
    /// Deactivations queued so far.
    private(set) var deactivations = 0
    private(set) var queuedActivations: [Int] = []
    private(set) var activated: Set<Int> = []
    private(set) var outcomes: [Int: M.StartOutcome] = [:]
    private(set) var violations: [String] = []
    /// The attempt whose successful activation is being handled right now.
    private var activationSucceeding: Int?

    mutating func send(_ event: M.Event) {
        for effect in machine.handle(event) {
            perform(effect)
        }
    }

    /// Finishes the oldest queued activation; returns its attempt.
    @discardableResult
    mutating func finishActivation(succeeded: Bool = true) -> Int? {
        guard !queuedActivations.isEmpty else { return nil }
        let attempt = queuedActivations.removeFirst()
        // Deactivations ahead of it have run already; it's next in line. A
        // failed activation leaves the session as it was.
        if sessionOps.first == .activate(attempt) { sessionOps.removeFirst() }
        if succeeded { sessionActive = true }
        runReadySessionOps()
        activationSucceeding = succeeded ? attempt : nil
        send(.activationFinished(attempt: attempt, succeeded: succeeded))
        activationSucceeding = nil
        // Whatever happened meanwhile, the attempt's fate is now decided.
        if outcomes[attempt] == nil { violations.append("attempt \(attempt) unresolved after activation") }
        return attempt
    }

    /// The most recently queued activation.
    var latestAttempt: Int? { activated.max() }

    /// Deactivations at the head of the queue run at once.
    private mutating func runReadySessionOps() {
        while sessionOps.first == .deactivate {
            sessionOps.removeFirst()
            sessionActive = false
        }
    }

    private mutating func perform(_ effect: M.Effect) {
        switch effect {
        case .activateSession(let attempt):
            if activated.contains(attempt) { violations.append("attempt \(attempt) activated twice") }
            activated.insert(attempt)
            queuedActivations.append(attempt)
            sessionOps.append(.activate(attempt))
        case .deactivateSession:
            sessionOps.append(.deactivate)
            deactivations += 1
            runReadySessionOps()
        case .startEngine(let attempt):
            if attempt != activationSucceeding {
                violations.append("engine started for \(attempt) without its activation succeeding")
            }
            // Kit contract: never prepare while rendering.
            if engineOn { violations.append("engine started while running") }
            engineOn = !engineFails
            send(.engineStartFinished(attempt: attempt, succeeded: !engineFails))
        case .stopEngine:
            if !engineOn { violations.append("engine stopped while stopped") }
            engineOn = false
        case .restartEngine:
            if !engineOn { violations.append("engine restarted while stopped") }
            if engineFails {
                engineOn = false
                send(.engineRestartFailed)
            }
        case .resolve(let attempt, let outcome):
            if !activated.contains(attempt) { violations.append("resolved unknown attempt \(attempt)") }
            if outcomes[attempt] != nil { violations.append("attempt \(attempt) resolved twice") }
            if outcome == .started, !state.isRunning { violations.append("attempt \(attempt) started but not running") }
            outcomes[attempt] = outcome
        }
    }
}

struct TransportMachineTests {

    // MARK: invariants over random event sequences

    /// Deterministic, so a failure reproduces from its seed.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private enum Step: CaseIterable {
        case play, pause, stop, began, endedResume, endedNoResume, deviceLost, configChange
        case activationSucceeds, activationFails, toggleEngineFailure

        /// Uniform draws spend most steps idle (pause, stop and unplug keep
        /// resetting), so favor the steps that lead into deeper states.
        var weight: Int {
            switch self {
            case .play, .activationSucceeds: 5
            case .began: 4
            case .endedResume: 3
            case .pause, .stop, .deviceLost, .toggleEngineFailure: 1
            case .endedNoResume, .configChange, .activationFails: 2
            }
        }

        static let weighted: [Step] = allCases.flatMap { Array(repeating: $0, count: $0.weight) }
    }

    @Test func randomSequencesKeepTheSafetyRules() {
        var visits: [String: Int] = [:]
        for seed in UInt64(1)...3000 {
            var rng = SplitMix64(state: seed)
            var h = Harness()
            var log: [Step] = []
            /// Playback is only allowed after a Play the user hasn't since
            /// taken back with pause, stop or an unplug.
            var playWanted = false
            var broken: [String] = []
            func check(_ rule: Bool, _ what: @autoclosure () -> String) {
                if !rule { broken.append(what()) }
            }

            for _ in 0..<40 {
                let step = Step.weighted.randomElement(using: &rng)!
                log.append(step)
                // Finishing an activation only counts if one is in flight.
                if ![.activationSucceeds, .activationFails].contains(step) || !h.queuedActivations.isEmpty {
                    visits["\(Self.label(h.state)) + \(step)", default: 0] += 1
                }
                let deactivationsBefore = h.deactivations
                switch step {
                case .play: h.send(.play); playWanted = true
                case .pause: h.send(.pause); playWanted = false
                case .stop: h.send(.stop); playWanted = false
                case .began: h.send(.interruptionBegan)
                case .endedResume: h.send(.interruptionEnded(shouldResume: true))
                case .endedNoResume: h.send(.interruptionEnded(shouldResume: false))
                case .deviceLost: h.send(.outputDeviceLost); playWanted = false
                case .configChange: h.send(.configurationChanged)
                case .activationSucceeds: h.finishActivation(succeeded: true)
                case .activationFails: h.finishActivation(succeeded: false)
                case .toggleEngineFailure: h.engineFails.toggle()
                }

                check(h.engineOn == h.state.isRunning, "engine \(h.engineOn ? "on" : "off") in \(h.state)")
                check(!h.state.isRunning || playWanted, "playing without a standing Play")
                // Activations finish in order, so playback implies every
                // earlier one is done.
                check(!h.state.isRunning || h.queuedActivations.isEmpty, "running with an activation in flight")
                if [.stop, .began].contains(step) {
                    check(h.sessionEndsReleased, "session still held after \(step)")
                }
                if step == .pause {
                    // Paused sessions stay active, so we stay the Now Playing
                    // app and lock-screen Play keeps routing to us.
                    check(h.deactivations == deactivationsBefore, "pause released the session")
                }
                if [.pause, .stop, .deviceLost].contains(step) {
                    check(h.state == .idle, "\(step) left \(h.state)")
                }
                if h.state.pendingAttempt != nil {
                    check(h.queuedActivations.last == h.state.pendingAttempt,
                          "pending attempt isn't the latest activation")
                }
            }

            // Drain: every attempt ever activated ends up resolved once.
            while h.finishActivation(succeeded: rng.next() % 2 == 0) != nil {}
            check(Set(h.outcomes.keys) == h.activated, "unresolved attempts")

            let violations = h.violations + broken
            #expect(violations.isEmpty, "seed \(seed): \(violations.first ?? "") after \(log)")
            if !violations.isEmpty { return }   // one reproducible failure is enough
        }

        // The sequences must actually reach every state with every event,
        // repeatedly, or the rules above prove little.
        let unreachable: Set = ["running + activationSucceeds", "running + activationFails"]
        let pairs = ["idle", "starting", "resuming", "running", "interrupted", "interrupted+pending"]
            .flatMap { state in Step.allCases.map { "\(state) + \($0)" } }
            .filter { !unreachable.contains($0) }
        let rare = pairs.filter { visits[$0, default: 0] < 20 }
        #expect(rare.isEmpty, "rarely reached: \(rare.map { "\($0): \(visits[$0, default: 0])" })")
    }

    private static func label(_ state: TransportMachine.State) -> String {
        switch state {
        case .idle: "idle"
        case .starting(_, let resuming): resuming ? "resuming" : "starting"
        case .running: "running"
        case .interrupted(let pending): pending == nil ? "interrupted" : "interrupted+pending"
        }
    }

    // MARK: scenarios (outcomes, not effect lists)

    @Test func playStartsAfterActivation() {
        var h = Harness()
        h.send(.play)
        #expect(h.state.isStarting && !h.engineOn)
        h.send(.play)   // joins rather than queueing a second activation
        #expect(h.activated.count == 1)
        let attempt = h.finishActivation()
        #expect(h.state == .running && h.engineOn)
        #expect(attempt.flatMap { h.outcomes[$0] } == .started)
    }

    @Test func pauseDuringActivationWins() {
        var h = Harness()
        h.send(.play)
        h.send(.pause)
        let attempt = h.finishActivation()
        #expect(attempt.flatMap { h.outcomes[$0] } == .cancelled)
        #expect(h.state == .idle && !h.engineOn)
        #expect(h.sessionActive)   // paused, not stopped
    }

    @Test func queuedFailedActivationsLeaveTheSessionInactive() {
        var h = Harness()
        h.send(.play)
        h.send(.pause)
        h.send(.play)
        h.finishActivation(succeeded: false)
        h.finishActivation(succeeded: false)
        #expect(!h.sessionActive && h.state == .idle)
    }

    @Test func pauseKeepsTheSessionStopReleasesIt() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.pause)
        #expect(!h.engineOn && h.sessionActive)
        h.send(.stop)
        #expect(!h.sessionActive)
    }

    @Test func failedEngineStartReleasesTheSession() {
        var h = Harness()
        h.engineFails = true
        h.send(.play)
        let attempt = h.finishActivation()
        #expect(attempt.flatMap { h.outcomes[$0] } == .failed)
        #expect(h.state == .idle && !h.sessionActive)
    }

    @Test func interruptionResumesWhenTheSystemSaysSo() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.interruptionBegan)
        #expect(!h.engineOn && !h.sessionActive)
        h.send(.interruptionEnded(shouldResume: true))
        h.finishActivation()
        #expect(h.state == .running)

        h.send(.interruptionBegan)
        h.send(.interruptionEnded(shouldResume: false))
        #expect(h.state == .idle && h.queuedActivations.isEmpty)
    }

    @Test func failedPlayDuringInterruptionKeepsTheResume() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.interruptionBegan)
        h.send(.play)
        let userAttempt = h.finishActivation(succeeded: false)
        #expect(userAttempt.flatMap { h.outcomes[$0] } == .failed)
        h.send(.interruptionEnded(shouldResume: true))
        h.finishActivation()
        #expect(h.state == .running)
    }

    @Test func resumeSupersedesAPlayStillActivating() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.interruptionBegan)
        h.send(.play)
        h.send(.interruptionEnded(shouldResume: true))
        let userAttempt = h.finishActivation()
        #expect(userAttempt.flatMap { h.outcomes[$0] } == .cancelled)
        h.finishActivation()
        #expect(h.state == .running)
    }

    @Test func playDuringInterruptionStillCountsWithoutAResume() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.interruptionBegan)
        h.send(.play)
        h.send(.interruptionEnded(shouldResume: false))
        h.finishActivation()
        #expect(h.state == .running)
    }

    /// Deliberate: a repeated `.began`, or one landing while the resume is
    /// still activating, doesn't forfeit the resume.
    @Test func repeatedInterruptionsKeepTheResume() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.interruptionBegan)
        h.send(.interruptionBegan)
        h.send(.interruptionEnded(shouldResume: true))
        h.send(.interruptionBegan)   // resume still activating
        h.finishActivation()
        #expect(!h.engineOn)
        h.send(.interruptionEnded(shouldResume: true))
        h.finishActivation()
        #expect(h.state == .running)
    }

    @Test func unplugNeverResumes() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.interruptionBegan)
        h.send(.outputDeviceLost)
        h.send(.interruptionEnded(shouldResume: true))
        #expect(h.state == .idle && h.queuedActivations.isEmpty)

        h.send(.play)
        h.send(.outputDeviceLost)   // mid-activation
        h.finishActivation()
        #expect(h.state == .idle && !h.engineOn && !h.sessionActive)
    }

    @Test func failedRestartAfterRouteChangeStopsCleanly() {
        var h = Harness()
        h.send(.play); h.finishActivation()
        h.send(.configurationChanged)
        #expect(h.state == .running && h.engineOn)
        h.engineFails = true
        h.send(.configurationChanged)
        #expect(h.state == .idle && !h.engineOn && !h.sessionActive)
    }
}
