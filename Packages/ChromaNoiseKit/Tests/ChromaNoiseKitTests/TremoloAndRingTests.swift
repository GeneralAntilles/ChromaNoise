import XCTest
@testable import ChromaNoiseKit

final class TremoloAndRingTests: XCTestCase {

    /// Mirrors reference check 14: envelope spans [1-depth, 1], bypass is exact.
    func testTremoloDepthAndBypass() {
        let sr = 48000.0
        var trem = Tremolo(periodSeconds: 1.0, depth: 0.6)
        var env = [Float](repeating: 0, count: Int(sr * 2))
        trem.fillEnvelope(into: &env, count: env.count, sampleRate: sr)
        XCTAssertEqual(env.min()!, 0.4, accuracy: 1e-3)
        XCTAssertEqual(env.max()!, 1.0, accuracy: 1e-3)

        var off = Tremolo(periodSeconds: 1.0, depth: 0.0)
        var flat = [Float](repeating: 0, count: 100)
        off.fillEnvelope(into: &flat, count: 100, sampleRate: sr)
        XCTAssertTrue(flat.allSatisfy { $0 == 1.0 })
        XCTAssertFalse(off.isActive)
    }

    func testRingBufferRoundTripAndUnderrun() {
        let ring = RenderRingBuffer(capacityFrames: 4096)
        let l = (0..<1000).map { Float($0) }
        let r = (0..<1000).map { Float(-$0) }
        XCTAssertEqual(ring.write(left: l, right: r, count: 1000), 1000)
        XCTAssertEqual(ring.availableToRead, 1000)

        var outL = [Float](repeating: -999, count: 1500)
        var outR = [Float](repeating: -999, count: 1500)
        let got = outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                ring.read(into: lp.baseAddress!, rp.baseAddress!, count: 1500)
            }
        }
        XCTAssertEqual(got, 1000)
        XCTAssertEqual(outL[0], 0)
        XCTAssertEqual(outL[999], 999)
        XCTAssertEqual(outR[500], -500)
        // Underrun tail is silence, not garbage.
        XCTAssertTrue(outL[1000...].allSatisfy { $0 == 0 })
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testRingBufferWrapAround() {
        let ring = RenderRingBuffer(capacityFrames: 2048)
        var outL = [Float](repeating: 0, count: 1536)
        var outR = [Float](repeating: 0, count: 1536)
        for round in 0..<10 {
            let l = [Float](repeating: Float(round), count: 1536)
            XCTAssertEqual(ring.write(left: l, right: l, count: 1536), 1536)
            let got = outL.withUnsafeMutableBufferPointer { lp in
                outR.withUnsafeMutableBufferPointer { rp in
                    ring.read(into: lp.baseAddress!, rp.baseAddress!, count: 1536)
                }
            }
            XCTAssertEqual(got, 1536)
            XCTAssertTrue(outL.allSatisfy { $0 == Float(round) }, "round \(round)")
        }
    }
}
