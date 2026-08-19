import XCTest
@testable import TottaCore

final class StillnessTrackerTests: XCTestCase {
    private func fp(_ v: Float) -> Fingerprint { Fingerprint(width: 1, height: 1, values: [v]) }

    func testCaptureFiresOnceAfterMinStill() {
        var t = StillnessTracker(motionThreshold: 5, minStillDuration: 1.0)
        XCTAssertEqual(t.feed(time: 0.0, fingerprint: fp(10)), .moving)
        XCTAssertEqual(t.feed(time: 0.2, fingerprint: fp(10)), .settling(0))
        if case .settling(let p) = t.feed(time: 0.7, fingerprint: fp(11)) {
            XCTAssertEqual(p, 0.5, accuracy: 1e-9)
        } else { XCTFail("settling expected") }
        XCTAssertEqual(t.feed(time: 1.2, fingerprint: fp(11)), .capture)
        XCTAssertEqual(t.feed(time: 1.5, fingerprint: fp(11)), .held)
        XCTAssertEqual(t.feed(time: 1.7, fingerprint: fp(80)), .moving)
        XCTAssertEqual(t.feed(time: 1.9, fingerprint: fp(80)), .settling(0))
        XCTAssertEqual(t.feed(time: 3.0, fingerprint: fp(80)), .capture)
    }

    func testMarkCapturedSuppressesAutoCapture() {
        var t = StillnessTracker(motionThreshold: 5, minStillDuration: 1.0)
        _ = t.feed(time: 0.0, fingerprint: fp(10))
        _ = t.feed(time: 0.2, fingerprint: fp(10))
        t.markCaptured()
        XCTAssertEqual(t.feed(time: 1.5, fingerprint: fp(10)), .held)
    }
}
