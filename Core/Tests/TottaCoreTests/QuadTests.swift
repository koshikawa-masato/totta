import XCTest
@testable import TottaCore

final class QuadTests: XCTestCase {
    func testRectQuad() {
        let q = Quad(rect: CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(q.topLeft, CGPoint(x: 10, y: 20))
        XCTAssertEqual(q.bottomRight, CGPoint(x: 110, y: 70))
        XCTAssertEqual(q.area, 5000)
        XCTAssertTrue(q.isAxisAlignedRect)
        XCTAssertEqual(q.correctedSize, CGSize(width: 100, height: 50))
        XCTAssertEqual(q.boundingBox, CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testCornerSubscriptAndClamp() {
        var q = Quad.fullFrame(CGSize(width: 100, height: 100))
        q[.bottomRight] = CGPoint(x: 150, y: -10)
        XCTAssertFalse(q.isAxisAlignedRect)
        let c = q.clamped(to: CGSize(width: 100, height: 100))
        XCTAssertEqual(c.bottomRight, CGPoint(x: 100, y: 0))
    }

    func testScaling() {
        let q = Quad.fullFrame(CGSize(width: 100, height: 50))
        let s = q.scaled(from: CGSize(width: 100, height: 50), to: CGSize(width: 200, height: 100))
        XCTAssertEqual(s.bottomRight, CGPoint(x: 200, y: 100))
    }
}
