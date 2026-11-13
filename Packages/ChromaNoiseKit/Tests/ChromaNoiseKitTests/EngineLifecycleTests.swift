import XCTest
import ChromaNoiseKit

/// The engine's threading contract: one worker per prepare, teardown joins it,
/// re-prepare (route / sample-rate change) never leaves a stale producer, and
/// an abandoned engine doesn't keep its worker alive.
final class EngineLifecycleTests: XCTestCase {

    private func pull(_ engine: NoiseEngine, frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: .nan, count: frames)
        var r = [Float](repeating: .nan, count: frames)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                engine.render(left: lp.baseAddress!, right: rp.baseAddress!, frameCount: frames)
            }
        }
        return (l, r)
    }

    /// Poll until the worker has produced audio (or give up after ~2 s).
    private func pullUntilAudible(_ engine: NoiseEngine, frames: Int) -> (l: [Float], r: [Float]) {
        for _ in 0..<200 {
            let out = pull(engine, frames: frames)
            if out.l.contains(where: { $0 != 0 }) { return out }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return pull(engine, frames: frames)
    }

    func testUnpreparedEngineRendersSilence() {
        let out = pull(NoiseEngine(), frames: 256)
        XCTAssertTrue(out.l.allSatisfy { $0 == 0 } && out.r.allSatisfy { $0 == 0 })
    }

    func testPreparedEngineProducesBoundedDecorrelatedStereo() {
        let engine = NoiseEngine()
        engine.prepare(sampleRate: 48000, maxFrames: 512)
        defer { engine.teardown() }

        let out = pullUntilAudible(engine, frames: 512)
        XCTAssertTrue(out.l.contains { $0 != 0 }, "worker never produced audio")
        XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) < 1 })
        XCTAssertTrue(out.r.allSatisfy { $0.isFinite && abs($0) < 1 })
        XCTAssertNotEqual(out.l, out.r, "channels should be independent streams")
    }

    func testRepreparingAndTearingDownIsCleanAndSilent() {
        let engine = NoiseEngine()
        // 96 and 192 kHz run a larger frame and hop.
        for rate in [48000.0, 44100.0, 16000.0, 96000.0, 192000.0, 48000.0] {
            engine.prepare(sampleRate: rate, maxFrames: 1024)
            let out = pullUntilAudible(engine, frames: 1024)
            XCTAssertTrue(out.l.contains { $0 != 0 }, "no audio at \(rate) Hz")
        }
        engine.teardown()
        engine.teardown()   // idempotent
        let out = pull(engine, frames: 256)
        XCTAssertTrue(out.l.allSatisfy { $0 == 0 }, "torn-down engine must render silence")
    }

    func testAbandonedEngineIsReleased() {
        weak var weakEngine: NoiseEngine?
        do {
            let engine = NoiseEngine()
            engine.prepare(sampleRate: 48000, maxFrames: 512)
            weakEngine = engine
        }
        XCTAssertNil(weakEngine, "the worker thread must not retain the engine")
    }

    #if canImport(Accelerate)
    /// The worker sleeps between refills; at the host's worst case (4096-frame
    /// pulls, as with the screen locked) it must still keep the ring fed.
    /// Realtime-paced, so only where the fast FFT makes timing dependable.
    /// Shared CI machines can stall any thread for a while, so a run with
    /// underruns is tried again: a worker too slow to keep up fails every
    /// time, a scheduling hiccup doesn't recur.
    func testWorkerKeepsUpWithLargestPullsAtRealtimePace() {
        var underruns: [Int] = []
        for _ in 1...3 {
            underruns.append(underrunsAtRealtimePace(frames: 4096))
            if underruns.last == 0 { return }
        }
        XCTFail("ring underran at realtime pace in every attempt: \(underruns)")
    }

    /// Underruns while pulling ~2 s of audio at `frames` per pull, in time.
    private func underrunsAtRealtimePace(frames: Int) -> Int {
        let engine = NoiseEngine()
        engine.prepare(sampleRate: 48000, maxFrames: frames)
        defer { engine.teardown() }
        _ = pullUntilAudible(engine, frames: frames)
        Thread.sleep(forTimeInterval: 0.2)   // let the lead fill
        let before = engine.underrunCount

        let period = Double(frames) / 48000
        let start = Date()
        for i in 1...24 {   // ~2 s of audio
            _ = pull(engine, frames: frames)
            Thread.sleep(until: start.addingTimeInterval(Double(i) * period))
        }
        return engine.underrunCount - before
    }
    #endif

    func testZeroMasterVolumeIsSilentAfterRamp() {
        let engine = NoiseEngine()
        engine.prepare(sampleRate: 48000, maxFrames: 512)
        defer { engine.teardown() }
        _ = pullUntilAudible(engine, frames: 512)

        engine.setMasterVolume(0)
        // Drain everything queued before the change, plus the ramp hop.
        var tail = [Float]()
        for _ in 0..<200 {
            tail = pull(engine, frames: 512).l
            if tail.allSatisfy({ $0 == 0 }) { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(tail.allSatisfy { $0 == 0 })
    }
}
