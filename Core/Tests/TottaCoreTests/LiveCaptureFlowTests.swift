import XCTest
@testable import TottaCore

/// カメラから来るフレーム列を StillnessTracker → PageCapture → DuplicateFilter に流し、
/// LiveScanner と同じ判断で見開きが 1 回ずつ取り込まれることを確認する。
final class LiveCaptureFlowTests: XCTestCase {
    struct Result { let page: CapturedPage; let frame: CGImage }

    func runFlow(_ frames: [(time: Double, image: CGImage)], settings: AnalysisSettings) -> [Result] {
        var tracker = StillnessTracker(motionThreshold: settings.motionThreshold, minStillDuration: settings.minStillDuration)
        var dup = DuplicateFilter()
        var results: [Result] = []
        var lastSample = -1.0
        for f in frames {
            guard lastSample < 0 || f.time - lastSample >= settings.samplingInterval else { continue }
            lastSample = f.time
            let fp = Fingerprint.motionFingerprint(f.image, width: settings.fingerprintWidth)
            if tracker.feed(time: f.time, fingerprint: fp) == .capture {
                var page = PageCapture.makePage(from: f.image, at: f.time, settings: settings, kind: .auto)
                let pfp = PageCapture.pageFingerprint(frame: f.image, quad: page.quad)
                let v = dup.evaluate(pfp, threshold: settings.duplicateThreshold)
                page.differenceFromPrevious = v.difference
                if v.keep { results.append(Result(page: page, frame: f.image)) }
            }
        }
        return results
    }

    func testEachSpreadCapturedOnce() throws {
        let frames = SyntheticFrames.bookSequence(pageCount: 5, hold: 1.5, transition: 0.8, rotation: 2, repeatPage: 2)
        var settings = AnalysisSettings()
        settings.minStillDuration = 0.7
        let results = runFlow(frames, settings: settings)
        XCTAssertEqual(results.count, 5, "times: \(results.map { $0.page.time })")
        XCTAssertEqual(results.map(\.page.time), results.map(\.page.time).sorted())
        for r in results {
            XCTAssertNotNil(r.page.confidence, "t=\(r.page.time) で枠が検出されなかった")
            XCTAssertLessThan(r.page.quad.area, 640.0 * 360.0 * 0.7)
            XCTAssertGreaterThan(r.page.quad.area, 640.0 * 360.0 * 0.3)
        }
        // 重複を除いたので、残った隣接ページ同士の差は十分大きい
        for r in results.dropFirst() {
            XCTAssertGreaterThan(r.page.differenceFromPrevious ?? 0, settings.duplicateThreshold)
        }
        // PDF まで通す
        let images = try results.map { try PageDetector.crop($0.frame, to: $0.page.quad) }
        var ex = ExportSettings(); ex.splitSpread = false   // 取り込みフローの確認なので見開きのまま 1 ページ
        let data = try PDFExporter.pdfData(pages: images, settings: ex)
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(doc.numberOfPages, 5)
    }

    func testDuplicateFilterCanBeDisabledAndForced() {
        var dup = DuplicateFilter()
        let a = Fingerprint(width: 1, height: 1, values: [10])
        let b = Fingerprint(width: 1, height: 1, values: [11])
        XCTAssertTrue(dup.evaluate(a, threshold: 2).keep)
        XCTAssertFalse(dup.evaluate(b, threshold: 2).keep)
        XCTAssertTrue(dup.evaluate(b, threshold: 2, force: true).keep)   // 手動取り込みは常に採用
        dup.reset()
        XCTAssertTrue(dup.evaluate(b, threshold: 0).keep)
        XCTAssertTrue(dup.evaluate(b, threshold: 0).keep)                 // 0 で無効
    }

    func testMakePageWithoutDetectionUsesFullFrame() {
        let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 400, height: 300))
        var s = AnalysisSettings()
        s.detectPages = false
        let page = PageCapture.makePage(from: img, at: 1, settings: s, kind: .manual)
        XCTAssertEqual(page.quad, Quad.fullFrame(CGSize(width: 400, height: 300)))
        XCTAssertNil(page.confidence)
    }
}

final class FrameTemplateTests: XCTestCase {
    private let template = FrameTemplate(quad: Quad(rect: CGRect(x: 100, y: 50, width: 800, height: 400)),
                                         spine: Spine(top: CGPoint(x: 500, y: 50), bottom: CGPoint(x: 500, y: 450)),
                                         frameSize: CGSize(width: 1000, height: 500))

    func testScalesToLargerFrame() {
        let size = CGSize(width: 2000, height: 1000)
        XCTAssertTrue(template.matchesAspect(of: size))
        let q = template.quad(for: size)
        XCTAssertEqual(q.topLeft, CGPoint(x: 200, y: 100))
        XCTAssertEqual(q.bottomRight, CGPoint(x: 1800, y: 900))
        XCTAssertEqual(template.spine(for: size)?.top, CGPoint(x: 1000, y: 100))
    }

    func testRejectsRotatedFrame() {
        // 縦向き(90 度回転)のフレームには適用しない
        XCTAssertFalse(template.matchesAspect(of: CGSize(width: 500, height: 1000)))
        // わずかな差(16:9 と 1.75:1 など)は許容
        XCTAssertTrue(template.matchesAspect(of: CGSize(width: 1920, height: 1000)))
    }

    func testMakePageUsesTemplateOnlyWhenAspectMatches() {
        let landscape = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 1000, height: 500))
        let portrait = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 500, height: 1000))
        var s = AnalysisSettings()
        s.detectPages = false
        let ok = PageCapture.makePage(from: landscape, at: 0, settings: s, kind: .auto, template: template)
        XCTAssertTrue(ok.usedTemplate)
        XCTAssertEqual(ok.quad.topLeft, CGPoint(x: 100, y: 50))
        XCTAssertNotNil(ok.spine)
        let fallback = PageCapture.makePage(from: portrait, at: 0, settings: s, kind: .auto, template: template)
        XCTAssertFalse(fallback.usedTemplate)
        XCTAssertEqual(fallback.quad, Quad.fullFrame(CGSize(width: 500, height: 1000)))
    }
}
