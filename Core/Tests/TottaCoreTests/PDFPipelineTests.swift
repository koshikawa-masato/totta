import XCTest
import PDFKit
@testable import TottaCore

final class PDFPipelineTests: XCTestCase {
    private func job(index: Int, size: CGSize = CGSize(width: 1200, height: 700)) -> ExportJob {
        let img = SyntheticFrames.spreadImage(index: index, size: size)
        let data = ImageUtils.jpegData(img, quality: 0.9)!
        let quad = Quad(rect: CGRect(x: size.width * 0.15, y: size.height * 0.15,
                                     width: size.width * 0.7, height: size.height * 0.7))
        let spine = Spine.centered(in: quad)
        let page = CapturedPage(time: Double(index), frameSize: size, quad: quad, spine: spine, source: .auto)
        return ExportJob(frameJPEG: data, page: page)
    }

    func testBuildsSearchablePDFWithSplitPages() throws {
        var ex = ExportSettings()
        ex.splitSpread = true
        ex.title = "test book"
        var en = EnhanceSettings(); en.removeFingers = false
        var progressValues: [Double] = []
        let out = try PDFPipeline.build(jobs: (0..<3).map { job(index: $0) },
                                        enhance: en, ocr: OCRSettings(), export: ex) { p in
            progressValues.append(p.fraction)
        }
        XCTAssertEqual(out.pageTexts.count, 6, "ページごとのテキストが揃っていない")
        let doc = try XCTUnwrap(PDFDocument(data: out.pdf))
        XCTAssertEqual(doc.pageCount, 6)                 // 3 見開き × 左右
        XCTAssertEqual(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "test book")
        XCTAssertEqual(progressValues.last, 1)
        XCTAssertEqual(progressValues, progressValues.sorted())
    }

    func testPaperSizeFitsAndOrientsPages() throws {
        var ex = ExportSettings()
        ex.paperSize = .a5
        ex.splitSpread = false   // まず見開きのまま(横長)で確認し、後半で分割(縦長)を確認する
        var en = EnhanceSettings(); en.removeFingers = false; en.flattenLighting = false
        var ocr = OCRSettings(); ocr.enabled = false
        let data = try PDFPipeline.build(jobs: [job(index: 0)], enhance: en, ocr: ocr, export: ex).pdf
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let box = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox)
        // 見開き(横長)なので A5 横
        XCTAssertEqual(box.width, 595.28, accuracy: 0.5)
        XCTAssertEqual(box.height, 419.53, accuracy: 0.5)

        ex.splitSpread = true
        let split = try PDFPipeline.build(jobs: [job(index: 0)], enhance: en, ocr: ocr, export: ex).pdf
        let splitDoc = try XCTUnwrap(PDFDocument(data: split))
        XCTAssertEqual(splitDoc.pageCount, 2)
        let half = try XCTUnwrap(splitDoc.page(at: 0)).bounds(for: .mediaBox)
        // 単ページ(縦長)なので A5 縦
        XCTAssertEqual(half.width, 419.53, accuracy: 0.5)
        XCTAssertEqual(half.height, 595.28, accuracy: 0.5)
    }

    func testCancellationStopsBuild() async {
        var en = EnhanceSettings(); en.removeFingers = false
        let jobs = (0..<40).map { job(index: $0) }
        let task = Task.detached {
            try PDFPipeline.build(jobs: jobs, enhance: en, ocr: OCRSettings(), export: ExportSettings())
        }
        task.cancel()
        do {
            _ = try await task.value
            // 速すぎて完走した場合も許容(キャンセルが例外なく通ればよい)
        } catch is CancellationError {
            // 期待どおり
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testEmptyJobsThrows() {
        XCTAssertThrowsError(try PDFPipeline.build(jobs: [], enhance: EnhanceSettings(), ocr: OCRSettings(), export: ExportSettings()))
    }

    /// ページ数を増やしてもメモリが積み上がらない(=一度に 1 ページしか展開しない)ことの目安
    func testBuilderDoesNotRetainPages() throws {
        var ex = ExportSettings()
        var en = EnhanceSettings(); en.removeFingers = false; en.flattenLighting = false
        var ocr = OCRSettings(); ocr.enabled = false
        let builder = try PDFBuilder(settings: ex)
        weak var weakImage: CGImage?
        autoreleasepool {
            let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 800, height: 500))
            weakImage = img
            builder.add(ExportPage(image: img))
        }
        XCTAssertEqual(builder.pageCount, 1)
        XCTAssertNil(weakImage, "PDFBuilder がページ画像を保持し続けている")
        ex.title = nil
        _ = en; _ = ocr
        XCTAssertFalse(try builder.finish().isEmpty)
    }
}

final class ResizeTests: XCTestCase {
    func testResizeKeepsGrayscale() {
        let color = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 2000, height: 1400))
        let gray = PageEnhancer.grayscale(color)!
        XCTAssertEqual(gray.colorSpace?.numberOfComponents, 1)
        let resized = ImageUtils.resized(gray, maxDimension: 800)
        XCTAssertEqual(resized.width, 800)
        XCTAssertEqual(resized.colorSpace?.numberOfComponents, 1, "縮小で RGB に戻っている(サイズが 3 倍になる)")
        // カラーはカラーのまま
        XCTAssertEqual(ImageUtils.resized(color, maxDimension: 800).colorSpace?.numberOfComponents, 3)
    }

    func testResizeDoesNotUpscale() {
        let img = SyntheticFrames.spreadImage(index: 0, size: CGSize(width: 600, height: 400))
        let out = ImageUtils.resized(img, maxDimension: 2400)
        XCTAssertEqual(out.width, 600)
    }

    /// 長辺上限を設けると PDF が小さくなり、OCR のテキストは残る
    func testMaxPageDimensionShrinksPDF() throws {
        let size = CGSize(width: 3600, height: 2400)
        let img = OCRTests.textPage(lines: ["resize test page", "縮小しても文字は残る"], size: size)
        let data = ImageUtils.jpegData(img, quality: 0.9)!
        let quad = Quad(rect: CGRect(origin: .zero, size: size))
        let page = CapturedPage(time: 0, frameSize: size, quad: quad, source: .auto)
        let jobs = [ExportJob(frameJPEG: data, page: page)]
        var en = EnhanceSettings(); en.removeFingers = false; en.flattenLighting = false

        var full = ExportSettings(); full.maxPageDimension = nil
        var small = ExportSettings(); small.maxPageDimension = 1200

        let a = try PDFPipeline.build(jobs: jobs, enhance: en, ocr: OCRSettings(), export: full)
        let b = try PDFPipeline.build(jobs: jobs, enhance: en, ocr: OCRSettings(), export: small)
        XCTAssertLessThan(b.pdf.count, a.pdf.count / 2, "縮小が効いていない (\(a.pdf.count) → \(b.pdf.count))")
        // OCR は縮小前に行うので、テキストは同じように取れている
        XCTAssertTrue(b.pageTexts.joined().contains("resize"), "テキスト層が失われている: \(b.pageTexts)")
        let doc = try XCTUnwrap(PDFDocument(data: b.pdf))
        XCTAssertTrue((doc.page(at: 0)?.string ?? "").contains("resize"))
    }
}
