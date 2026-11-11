import ChromaNoiseKit
import Foundation
import Testing
@testable import ChromaNoise

/// `PlayerModel` against a host with no audio stack, a clock the test moves
/// and a scratch defaults suite.
@MainActor
struct PlayerModelTests {
    let host = FakeAudioHost()
    let clock = TestClock()
    let scratch = ScratchDefaults()

    private func makeModel() -> PlayerModel {
        PlayerModel(host: host, clock: clock, defaults: scratch.defaults)
    }

    // MARK: sleep timer

    /// Advances the clock a fade step at a time until the timer has stopped
    /// playback, returning the volume the host was given at each step.
    private func runFade(_ model: PlayerModel) async -> [Float] {
        let before = host.volumes.count
        let step = Duration.seconds(PlayerModel.sleepFadeSeconds) / 60
        for _ in 0..<60 {
            // The timer measures its next step from when it goes back to
            // sleep, so only move the clock once it has.
            await waitFor("the timer to sleep again") { clock.sleeperCount == 1 }
            let seen = host.volumes.count
            clock.advance(by: step)
            await waitFor("a fade step") { host.volumes.count > seen }
        }
        await waitFor("the timer to expire") { model.sleepTimer == nil }
        return Array(host.volumes[before...])
    }

    @Test func sleepTimerFadesThenStopsAndRestoresTheVolume() async {
        let model = makeModel()
        model.masterVolume = 0.8
        await model.play()
        model.setSleepTimer(minutes: 1)
        #expect(model.sleepTimer?.minutes == 1)
        await waitFor("the timer to sleep") { clock.sleeperCount == 1 }

        // Nothing happens until the last 15 s.
        let untouched = host.volumes.count
        clock.advance(by: .seconds(44))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(host.volumes.count == untouched)
        #expect(host.count(.stop) == 0)

        // The fade begins: first step, then one every quarter second.
        clock.advance(by: .seconds(1))
        await waitFor("the fade to begin") { host.volumes.count > untouched }
        #expect(abs(host.volumes.last! - 0.8 * (59.0 / 60) * (59.0 / 60)) < 1e-5)

        let fade = await runFade(model)
        // Falls all the way to silence without ever rising, then the stop
        // puts the volume back for the next Play.
        let falling = fade.dropLast()
        #expect(zip(falling, falling.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(falling.last == 0)
        #expect(fade.last == 0.8)
        #expect(host.count(.stop) == 1)
        #expect(!model.isPlaying)
        #expect(model.sleepTimer == nil)
    }

    @Test func movingTheVolumeMidFadeStaysFaded() async {
        let model = makeModel()
        model.masterVolume = 0.8
        await model.play()
        model.setSleepTimer(minutes: 1)
        await waitFor("the timer to sleep") { clock.sleeperCount == 1 }
        let seen = host.volumes.count
        clock.advance(by: .seconds(45))
        await waitFor("the fade to begin") { host.volumes.count > seen }

        model.masterVolume = 0.4
        #expect(abs(host.volumes.last! - 0.4 * (59.0 / 60) * (59.0 / 60)) < 1e-5)
    }

    @Test func pauseCancelsTheTimerAndUndoesItsFade() async {
        let model = makeModel()
        model.masterVolume = 0.8
        await model.play()
        model.setSleepTimer(minutes: 1)
        await waitFor("the timer to sleep") { clock.sleeperCount == 1 }
        let seen = host.volumes.count
        clock.advance(by: .seconds(50))
        await waitFor("the fade to begin") { host.volumes.count > seen }

        model.pause()
        #expect(model.sleepTimer == nil)
        #expect(host.volumes.last == 0.8)
        await waitFor("the timer task to end") { clock.sleeperCount == 0 }

        // Long past the deadline, the cancelled timer does nothing more.
        let settled = host.volumes.count
        clock.advance(by: .seconds(600))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(host.count(.stop) == 0)
        #expect(host.volumes.count == settled)
    }

    @Test func replacingTheTimerStartsOver() async {
        let model = makeModel()
        await model.play()
        model.setSleepTimer(minutes: 1)
        await waitFor("the first timer to sleep") { clock.sleeperCount == 1 }
        model.setSleepTimer(minutes: 5)
        #expect(model.sleepTimer?.minutes == 5)

        // Past the first timer's deadline: still playing.
        clock.advance(by: .seconds(120))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(host.count(.stop) == 0)
        #expect(model.sleepTimer != nil)
    }

    /// An interruption mid-timer doesn't cancel it, and expiry still stops
    /// the host, which is what disarms the interruption's resume.
    @Test func timerSurvivesAnInterruptionAndStillStops() async {
        let model = makeModel()
        await model.play()
        model.setSleepTimer(minutes: 1)
        await waitFor("the timer to sleep") { clock.sleeperCount == 1 }

        host.set(.interrupted(pendingAttempt: nil))
        #expect(!model.isPlaying)
        #expect(model.sleepTimer != nil)

        let seen = host.volumes.count
        clock.advance(by: .seconds(45))
        await waitFor("the fade to begin") { host.volumes.count > seen }
        _ = await runFade(model)
        #expect(host.count(.stop) == 1)
    }

    // MARK: starting

    @Test func playReportsSuccessAndClearsAnOldError() async {
        let model = makeModel()
        struct Boom: Error {}
        let failing = StartGate()
        failing.finish(.failure(Boom()))
        host.scriptedStarts = [failing.task]
        #expect(await model.play() == false)
        #expect(model.errorMessage != nil)

        #expect(await model.play())
        #expect(model.isPlaying)
        #expect(model.errorMessage == nil)
        #expect(model.playStartedAt != nil)
    }

    @Test func aCancelledStartIsNotAnError() async {
        let model = makeModel()
        let gate = StartGate()
        gate.finish(.failure(CancellationError()))
        host.scriptedStarts = [gate.task]
        #expect(await model.play() == false)
        #expect(model.errorMessage == nil)
        #expect(host.count(.start) == 1)
    }

    /// Play pressed during an interruption, which then ends with a resume:
    /// the transport cancels the explicit start in favour of the resume, and
    /// that resume's outcome is what Play (and so Siri) reports.
    @Test func playCancelledByAnInterruptionResumeFollowsTheResume() async {
        let model = makeModel()
        let pressed = StartGate(), resume = StartGate()
        host.scriptedStarts = [pressed.task, resume.task]
        host.set(.interrupted(pendingAttempt: nil))

        let playing = Task { await model.play() }
        await waitFor("the start to be requested") { host.count(.start) == 1 }
        host.set(.interrupted(pendingAttempt: 1))

        // The interruption ends; the resume (attempt 2) replaces attempt 1.
        host.set(.starting(attempt: 2, resuming: true))
        pressed.finish(.failure(CancellationError()))
        await waitFor("Play to join the resume") { host.count(.start) == 2 }

        host.set(.running)
        resume.finish()
        #expect(await playing.value)
        #expect(model.errorMessage == nil)
    }

    @Test func togglePausesAStartStillActivating() async {
        let model = makeModel()
        let gate = StartGate()
        host.scriptedStarts = [gate.task]
        model.togglePlayback()
        host.set(.starting(attempt: 1, resuming: false))
        #expect(host.calls == [.start])
        #expect(model.isPlayingOrStarting && !model.isPlaying)

        model.togglePlayback()
        #expect(host.calls == [.start, .pause])
        gate.finish(.failure(CancellationError()))
    }

    // MARK: sounds

    @Test func loadingAPresetNormalizesItAndPaintingMarksItEdited() throws {
        let model = makeModel()
        let blue = try #require(model.presets.first { $0.name == "Blue" })
        model.load(blue, as: .builtIn(name: "Blue"))
        #expect(model.bandAmps.max() == 1)
        #expect(!model.isEdited)
        #expect(host.applied.last?.amps == model.bandAmps)

        model.bandAmps[3] = 0.25
        #expect(model.isEdited)
        #expect(model.displayName == "Blue")
        #expect(host.applied.last?.amps[3] == 0.25)

        model.revert()
        #expect(!model.isEdited)
    }

    @Test func turningSwellOnStartsAtASlowWave() {
        let model = makeModel()
        #expect(model.tremoloPeriodSeconds < 2)
        model.tremoloDepth = 0.5
        #expect(model.tremoloPeriodSeconds == 8)
        // An already chosen period is kept, a fast one included.
        for chosen: Float in [3, 1.5, 0.5] {
            model.tremoloPeriodSeconds = chosen
            model.tremoloDepth = 0
            model.tremoloDepth = 0.5
            #expect(model.tremoloPeriodSeconds == chosen)
        }
    }

    /// Built-ins are scaled to fill the painter; a saved sound comes back
    /// with the bars it was painted with.
    @Test func loadingASavedSoundKeepsItsBars() {
        let model = makeModel()
        var amps = [Float](repeating: 0.1, count: DSPConstants.bandCount)
        amps[5] = 0.5
        let id = UUID()
        model.load(Phonon(name: "Quiet", amps: amps), as: .saved(id: id))
        #expect(model.bandAmps == amps)
        #expect(!model.isEdited)

        // One that peaks above the painter's top is scaled to fit.
        amps[5] = 4
        model.load(Phonon(name: "Loud", amps: amps), as: .saved(id: id))
        #expect(model.bandAmps.max() == 1)
        #expect(model.bandAmps[0] == 0.025)
    }

    @Test func theRingIsSizedForTheSampleRate() {
        #expect(StandaloneAudioHost.maxFramesPerRender(atSampleRate: 16000) == 4096)
        #expect(StandaloneAudioHost.maxFramesPerRender(atSampleRate: 44100) == 4096)
        #expect(StandaloneAudioHost.maxFramesPerRender(atSampleRate: 48000) == 4096)
        #expect(StandaloneAudioHost.maxFramesPerRender(atSampleRate: 96000) == 8192)
        #expect(StandaloneAudioHost.maxFramesPerRender(atSampleRate: 192000) == 16384)
    }

    // MARK: persistence

    @Test func firstLaunchStartsOnBrown() {
        let model = makeModel()
        #expect(model.selection == .builtIn(name: "Brown"))
        #expect(model.masterVolume == 0.7)
        #expect(!model.isPlaying)
    }

    @Test func theLastSoundSurvivesARelaunchEditsIncluded() throws {
        let first = makeModel()
        let pink = try #require(first.presets.first { $0.name == "Pink" })
        first.load(pink, as: .builtIn(name: "Pink"))
        first.bandAmps[10] = 0.5
        first.masterVolume = 0.3
        first.saveState()

        let second = makeModel()
        #expect(second.selection == .builtIn(name: "Pink"))
        #expect(second.bandAmps == first.bandAmps)
        #expect(second.isEdited)
        #expect(second.masterVolume == 0.3)
        #expect(!second.isPlaying, "never auto-plays")
        // Revert still goes back to Pink as loaded.
        second.revert()
        #expect(second.bandAmps == first.loadedPhonon?.amps)
    }

    /// Rewrites the saved state's JSON, as a corrupt or older write would be.
    private func rewriteSavedState(_ change: (inout [String: Any]) -> Void) throws {
        let data = try #require(scratch.defaults.data(forKey: "lastSound"))
        var state = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&state)
        scratch.defaults.set(try JSONSerialization.data(withJSONObject: state), forKey: "lastSound")
    }

    @Test func anUnplayableSavedSoundFallsBackToTheDefault() throws {
        makeModel().saveState()
        try rewriteSavedState { state in
            var phonon = state["phonon"] as! [String: Any]
            phonon["amps"] = [1, 1, 1]
            state["phonon"] = phonon
        }
        let model = makeModel()
        #expect(model.selection == .builtIn(name: "Brown"))
        #expect(model.bandAmps.count == DSPConstants.bandCount)
    }

    @Test func aRemovedBuiltInRestoresAsCustom() throws {
        makeModel().saveState()
        try rewriteSavedState { state in
            state["selection"] = ["builtIn": ["name": "Grey"]]
        }
        let model = makeModel()
        #expect(model.selection == nil)
        #expect(model.displayName == "Custom")
        #expect(!model.isEdited)
    }

    @Test func anOutOfRangeSavedVolumeIsClamped() throws {
        makeModel().saveState()
        try rewriteSavedState { $0["masterVolume"] = 7 }
        #expect(makeModel().masterVolume == 1)
    }
}
