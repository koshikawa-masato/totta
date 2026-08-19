import XCTest
@testable import TottaCore

final class PageDetectorTests: XCTestCase {
    func testDetectsSpreadRectangle() throws {
        let size = CGSize(width: 1280, height: 720)
        let img = SyntheticFrames.spreadImage(index: 0, size: size, rotationDegrees: 3)
        let det = try XCTUnwrap(try PageDetector.detect(in: img))
        // 見開きは画像の 70% x 70% の領域(±回転)
        let expected = CGRect(x: 1280 * 0.15, y: 720 * 0.15, width: 1280 * 0.7, height: 720 * 0.7)
        let bb = det.quad.boundingBox
        XCTAssertEqual(bb.midX, expected.midX, accuracy: 30)
        XCTAssertEqual(bb.midY, expected.midY, accuracy: 30)
        XCTAssertEqual(det.quad.correctedSize.width, expected.width, accuracy: 60)
        XCTAssertEqual(det.quad.correctedSize.height, expected.height, accuracy: 60)
        XCTAssertFalse(det.quad.isAxisAlignedRect)

        let cropped = try PageDetector.crop(img, to: det.quad)
        XCTAssertEqual(CGFloat(cropped.width), expected.width, accuracy: 80)
        XCTAssertEqual(CGFloat(cropped.height), expected.height, accuracy: 80)
    }

    func testAxisAlignedCropIsPlainCrop() throws {
        let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 400, height: 300))
        let cropped = try PageDetector.crop(img, to: Quad(rect: CGRect(x: 10, y: 20, width: 100, height: 50)))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 50)
        let full = try PageDetector.crop(img, to: Quad.fullFrame(CGSize(width: 400, height: 300)))
        XCTAssertEqual(full.width, 400)
    }

    func testResized() {
        let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 800, height: 400))
        let r = ImageUtils.resized(img, maxDimension: 200)
        XCTAssertEqual(r.width, 200)
        XCTAssertEqual(r.height, 100)
    }
}

final class SpreadDetectionTests: XCTestCase {
    /// のどで折れた見開き: 左右のページが別々の傾きを持ち、間に暗い溝がある
    static func foldedSpread(size: CGSize = CGSize(width: 1600, height: 900)) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.17, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        func page(_ pts: [CGPoint]) {
            ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1))
            ctx.move(to: pts[0]); for p in pts.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.fillPath()
        }
        // 左ページ(左端が少し手前に倒れている台形)、右ページ(右端が少し奥)
        page([CGPoint(x: 220, y: 200), CGPoint(x: 780, y: 240), CGPoint(x: 780, y: 690), CGPoint(x: 180, y: 720)])
        page([CGPoint(x: 800, y: 240), CGPoint(x: 1380, y: 190), CGPoint(x: 1420, y: 730), CGPoint(x: 800, y: 690)])
        // 本文っぽい線
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.setLineWidth(3)
        for l in 0..<14 {
            let t = CGFloat(l) / 14
            ctx.move(to: CGPoint(x: 260, y: 270 + t * 400)); ctx.addLine(to: CGPoint(x: 730, y: 290 + t * 380)); ctx.strokePath()
            ctx.move(to: CGPoint(x: 850, y: 290 + t * 380)); ctx.addLine(to: CGPoint(x: 1340, y: 250 + t * 420)); ctx.strokePath()
        }
        return ctx.makeImage()!
    }

    func testFoldedSpreadIsDetectedAsTwoPagesWithSpine() throws {
        let img = Self.foldedSpread()
        let det = try XCTUnwrap(try PageDetector.detect(in: img))
        XCTAssertNotNil(det.spine, "2 ページが結合されていない: \(det.quad)")
        // 外枠は両ページを含む
        let bb = det.quad.boundingBox
        XCTAssertLessThan(bb.minX, 260)
        XCTAssertGreaterThan(bb.maxX, 1340)
        // のど線は中央付近
        if let s = det.spine {
            XCTAssertEqual(s.top.x, 790, accuracy: 40)
            XCTAssertEqual(s.bottom.x, 790, accuracy: 40)
        }
        // 左右別補正で 2 ページ分の幅がある
        let cropped = try PageDetector.crop(img, to: det.quad, spine: det.spine)
        XCTAssertGreaterThan(cropped.width, 1000)
        XCTAssertGreaterThan(Double(cropped.width) / Double(cropped.height), 1.8)
    }

    func testCropWithSpineStitchesEqualHalves() throws {
        let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 1200, height: 700))
        let quad = Quad(rect: CGRect(x: 180, y: 105, width: 840, height: 490))
        let spine = Spine(top: CGPoint(x: 600, y: 105), bottom: CGPoint(x: 600, y: 595))
        let out = try PageDetector.crop(img, to: quad, spine: spine)
        XCTAssertEqual(out.width % 2, 0)
        XCTAssertEqual(out.width, 840, accuracy: 4)
        XCTAssertEqual(out.height, 490, accuracy: 4)
        let halves = PDFExporter.splitSpread(out, rightToLeft: false)
        XCTAssertEqual(halves[0].width, halves[1].width)
    }
}

final class SpreadFitTests: XCTestCase {
    /// 幅 w、高さ h の画像に対する合成マスク(見開き全体が台形、右ページだけ矩形で見つかった想定)
    private func makeMask(w: Int, h: Int, fill: (CGPoint) -> Bool) -> PageDetector.DocumentMask {
        let gw = 160, gh = Int((CGFloat(gw) * CGFloat(h) / CGFloat(w)).rounded())
        let cell = CGSize(width: CGFloat(w) / CGFloat(gw), height: CGFloat(h) / CGFloat(gh))
        var cells = [Bool](repeating: false, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw {
            let p = CGPoint(x: (CGFloat(x) + 0.5) * cell.width, y: (CGFloat(y) + 0.5) * cell.height)
            cells[y * gw + x] = fill(p)
        } }
        return PageDetector.DocumentMask(width: gw, height: gh, cells: cells, cellSize: cell, confidence: 0.9)
    }

    func testFitSpreadFromRightPageAndMask() throws {
        // 見開き: 左ページ (100,120)-(800,120)-(800,700)-(40,720) 台形、右ページ (800,120)-(1500,140)-(1520,700)-(800,700)
        let mask = makeMask(w: 1600, h: 900) { p in
            (p.x >= 40 + (120 - p.y) * 0 && p.x <= 1520 && p.y >= 120 && p.y <= 720) &&
            !(p.x < 100 && p.y < 400)   // 左上を少し欠けさせる(左ページの左辺が斜め)
        }
        let right = DetectedPage(quad: Quad(topLeft: CGPoint(x: 800, y: 120), topRight: CGPoint(x: 1500, y: 140),
                                            bottomRight: CGPoint(x: 1520, y: 700), bottomLeft: CGPoint(x: 800, y: 700)), confidence: 1)
        let spread = try XCTUnwrap(PageDetector.fitSpread(mask: mask, page: right))
        XCTAssertNotNil(spread.spine)
        XCTAssertEqual(spread.spine!.top.x, 800, accuracy: 1)
        XCTAssertLessThan(spread.quad.topLeft.x, 200)
        XCTAssertLessThan(spread.quad.bottomLeft.x, 80)
        XCTAssertEqual(spread.quad.topRight, right.quad.topRight)
        XCTAssertEqual(spread.quad.bottomRight, right.quad.bottomRight)
    }

    func testFitSpreadRejectsWhenRectangleCoversMask() {
        let mask = makeMask(w: 1600, h: 900) { p in p.x >= 200 && p.x <= 1400 && p.y >= 150 && p.y <= 750 }
        let whole = DetectedPage(quad: Quad(rect: CGRect(x: 200, y: 150, width: 1200, height: 600)), confidence: 1)
        XCTAssertNil(PageDetector.fitSpread(mask: mask, page: whole))
    }

    func testFitSpreadRejectsWhenRemainderIsTiny() {
        let mask = makeMask(w: 1600, h: 900) { p in p.x >= 700 && p.x <= 1400 && p.y >= 150 && p.y <= 750 }
        let right = DetectedPage(quad: Quad(rect: CGRect(x: 760, y: 150, width: 640, height: 600)), confidence: 1)
        XCTAssertNil(PageDetector.fitSpread(mask: mask, page: right))
    }

    func testWideSingleRectangleGetsCenteredSpine() throws {
        // 平らな見開き(1 つの矩形として検出される)→ のど線が中央に付く
        let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 1280, height: 720), rotationDegrees: 2)
        let det = try XCTUnwrap(try PageDetector.detect(in: img))
        XCTAssertNotNil(det.spine)
        if let s = det.spine {
            XCTAssertEqual(s.top.x, (det.quad.topLeft.x + det.quad.topRight.x) / 2, accuracy: 1)
        }
    }
}
