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
        for rate in [48000.0, 44100.0, 16000.0, 48000.0] {
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
