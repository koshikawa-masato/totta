import XCTest
import CoreText
import PDFKit
@testable import TottaCore

final class OCRTests: XCTestCase {
    /// 文字を描いた白いページ画像
    static func textPage(lines: [String], size: CGSize = CGSize(width: 1400, height: 900)) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 48, nil)
        for (i, text) in lines.enumerated() {
            let attr = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 100, y: size.height - 150 - CGFloat(i) * 90)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    func testRecognizesJapaneseAndEnglish() throws {
        let img = Self.textPage(lines: ["totta scan test", "書籍の見開きを取り込む"])
        let lines = try PageOCR.recognize(img, settings: OCRSettings())
        let all = lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(all.contains("totta"), all)
        XCTAssertTrue(all.contains("見開き"), all)
        // 位置: 1 行目は上側にある(正規化・原点左下なので y が大きい)
        let first = try XCTUnwrap(lines.first { $0.text.contains("totta") })
        XCTAssertGreaterThan(first.boundingBox.midY, 0.7)
        XCTAssertLessThan(first.boundingBox.minX, 0.15)
    }

    func testSearchablePDFContainsText() throws {
        let img = Self.textPage(lines: ["Hello searchable PDF", "検索できるスキャン"])
        let lines = try PageOCR.recognize(img, settings: OCRSettings())
        XCTAssertFalse(lines.isEmpty)
        let data = try PDFExporter.pdfData(exportPages: [ExportPage(image: img, textLines: lines)], settings: ExportSettings())
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 1)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("searchable"), text)
        XCTAssertTrue(text.contains("検索"), text)
        // 検索でヒットする位置が画像上のおおよその位置と一致する
        let hits = doc.findString("searchable", withOptions: [])
        XCTAssertFalse(hits.isEmpty)
        if let sel = hits.first, let page = sel.pages.first {
            let b = sel.bounds(for: page)
            let pageBounds = page.bounds(for: .mediaBox)
            XCTAssertGreaterThan(b.midY / pageBounds.height, 0.7, "hit y=\(b)")
        }
    }
}

final class ExportPipelineTests: XCTestCase {
    /// 書き出しパイプライン全体: 影あり+指ありの見開き → 補正 → 分割 → OCR → 検索できる PDF
    func testEnhanceThenOCRProducesSearchableSplitPDF() throws {
        // 文字入りページに影と指を合成
        let base = OCRTests.textPage(lines: ["Left page alpha", "右ページは別の内容"], size: CGSize(width: 1600, height: 900))
        let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // 影(半透明の暗いグラデーション)
        let colors = [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1600, y: 0), options: [])
        // 指
        ctx.setFillColor(CGColor(red: 0.85, green: 0.6, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 1400, y: 0, width: 80, height: 200))
        let img = ctx.makeImage()!

        var en = EnhanceSettings()
        en.removeFingers = true
        let enhanced = try PageEnhancer.enhance(img, settings: en)
        // 手が写っていない合成画像なので、肌色があっても消さない(誤爆させない)
        XCTAssertEqual(enhanced.fingerCoverage, 0, accuracy: 0.0001)

        let halves = PDFExporter.splitSpread(enhanced.image, rightToLeft: false)
        XCTAssertEqual(halves.count, 2)
        let pages = try halves.map { ExportPage(image: $0, textLines: try PageOCR.recognize($0, settings: OCRSettings())) }
        XCTAssertTrue(pages[0].textLines.contains { $0.text.contains("alpha") }, "\(pages[0].textLines)")
        XCTAssertTrue(pages[1].textLines.isEmpty || !pages[1].textLines.contains { $0.text.contains("alpha") })

        var s = ExportSettings()
        s.splitSpread = true
        let data = try PDFExporter.pdfData(exportPages: pages, settings: s)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertTrue((doc.page(at: 0)?.string ?? "").contains("alpha"))
    }
}
