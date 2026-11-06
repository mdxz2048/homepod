import XCTest
@testable import HFLatencyControlCore

final class LatencyMathTests: XCTestCase {
    func testMillisToFramesAtPhaseBoundaries() throws {
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 0, rate: 48_000).frames, 0)
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 1_000, rate: 48_000).frames, 48_000)
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 2_000, rate: 44_100).frames, 88_200)
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 3_000, rate: 48_000).frames, 144_000)
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 3_000, rate: 44_100).frames, 132_300)
    }

    func testSubMillisecondRounding() throws {
        // 1 ms at 44100 Hz is 44.1 frames; half-to-even not relied on, but the
        // value must stay inside [0, 10*rate] and round to the nearest integer.
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 1, rate: 44_100).frames, 44)
        XCTAssertEqual(try LatencyMath.frames(milliseconds: 1, rate: 48_000).frames, 48)
    }

    func testRangeRejection() {
        for bad in [-1, 3_001, 10_000] {
            XCTAssertThrowsError(try LatencyMath.frames(milliseconds: bad, rate: 48_000)) { error in
                guard case LatencyMathError.millisecondsOutOfRange(let value) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(value, bad)
            }
        }
    }

    func testRateRejection() {
        for bad in [0.0, 44_101.0, -48_000.0, Double.nan] {
            XCTAssertThrowsError(try LatencyMath.frames(milliseconds: 100, rate: bad)) { error in
                guard case LatencyMathError.unsupportedRate = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testTenSecondCeiling() {
        XCTAssertEqual(LatencyMath.maxLatencyFrames(rate: 44_100), 441_000)
        XCTAssertEqual(LatencyMath.maxLatencyFrames(rate: 48_000), 480_000)
        let plan = try! LatencyMath.frames(milliseconds: 3_000, rate: 48_000)
        XCTAssertLessThanOrEqual(plan.frames, LatencyMath.maxLatencyFrames(rate: 48_000))
    }

    func testMillisecondsFromFrames() {
        XCTAssertEqual(LatencyMath.milliseconds(frames: 48_000, rate: 48_000), 1_000.0, accuracy: 0.001)
        XCTAssertEqual(LatencyMath.milliseconds(frames: 88_200, rate: 44_100), 2_000.0, accuracy: 0.001)
        XCTAssertEqual(LatencyMath.milliseconds(frames: 1_000, rate: 0), 0.0)
    }

    func testRevisionSemantics() {
        XCTAssertEqual(LatencyMath.expectedRevision(previousRevision: 1, previousFrames: 0, requestedFrames: 0), 1,
                       "idempotent write must not increment revision")
        XCTAssertEqual(LatencyMath.expectedRevision(previousRevision: 1, previousFrames: 0, requestedFrames: 96_000), 2,
                       "changed write must increment revision by one")
        XCTAssertEqual(LatencyMath.expectedRevision(previousRevision: 7, previousFrames: 48_000, requestedFrames: 0), 8)
    }

    func testMaxUInt64RevisionWrapsLikeDriverAtomicIncrement() {
        let result = LatencyMath.expectedRevision(previousRevision: UInt64.max,
                                                  previousFrames: 1, requestedFrames: 2)
        // Matches the driver's atomic_fetch_add wrap; only verifies no trap.
        XCTAssertEqual(result, 0)
    }
}
