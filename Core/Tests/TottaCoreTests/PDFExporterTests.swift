import XCTest
import PDFKit
@testable import TottaCore

final class PDFExporterTests: XCTestCase {
    private func solid(_ w: Int, _ h: Int) -> CGImage {
        SyntheticFrames.spreadImage(index: 1, size: CGSize(width: w, height: h))
    }

    func testPageCountAndSize() throws {
        var s = ExportSettings()
        s.dpi = 100
        s.splitSpread = false
        let data = try PDFExporter.pdfData(pages: [solid(400, 200), solid(300, 300)], settings: s)
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(doc.numberOfPages, 2)
        let box1 = doc.page(at: 1)!.getBoxRect(.mediaBox)
        XCTAssertEqual(box1.width, 400 * 72 / 100, accuracy: 0.01)
        XCTAssertEqual(box1.height, 200 * 72 / 100, accuracy: 0.01)
        let box2 = doc.page(at: 2)!.getBoxRect(.mediaBox)
        XCTAssertEqual(box2.width, 300 * 72 / 100, accuracy: 0.01)
    }

    func testSplitSpreadDoublesPages() throws {
        var s = ExportSettings()
        s.splitSpread = true
        let data = try PDFExporter.pdfData(pages: [solid(400, 200), solid(400, 200)], settings: s)
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(doc.numberOfPages, 4)
        XCTAssertEqual(doc.page(at: 1)!.getBoxRect(.mediaBox).width, 200 * 72 / 150, accuracy: 0.01)
    }

    /// 既定は見開き分割。ただし縦長(片ページ)の画像は分割しない
    func testSplitSpreadIsDefaultAndSkipsPortrait() throws {
        XCTAssertTrue(ExportSettings().splitSpread)
        let data = try PDFExporter.pdfData(pages: [solid(400, 200), solid(200, 400)], settings: ExportSettings())
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(doc.numberOfPages, 3, "横長は 2 分割、縦長はそのまま")
        XCTAssertEqual(PDFExporter.splitSpread(solid(200, 400), rightToLeft: false).count, 1)
    }

    func testJPEGQualityAffectsSize() throws {
        var lo = ExportSettings(); lo.jpegQuality = 0.2
        var hi = ExportSettings(); hi.jpegQuality = 0.98
        let img = solid(1200, 800)
        let a = try PDFExporter.pdfData(pages: [img], settings: lo)
        let b = try PDFExporter.pdfData(pages: [img], settings: hi)
        XCTAssertLessThan(a.count, b.count)
    }


    /// 写真の傾きで Vision の行 bbox が縦に膨らみ(実機: 行ピッチ ≈ 23pt に対し bbox 高さ 39〜47pt)、
    /// しかも行ごとに高さがばらつく条件でも、PDFKit(プレビュー / Spotlight / page.string)が行順を入れ替えないこと。
    /// 修正前は透明テキストのグリフが縦に重なり、段落が 1 ブロックに誤統合されて行順が崩れた
    /// (高さが全行同じだと再現しないので、実機で観測した比率をそのまま使う)。
    func testPDFKitPreservesLineOrderWithOverlappingLineBoxes() throws {
        let img = solid(1152, 819)
        let texts = [
            "固定したカメラの前で書籍の見開きを開いて止めてめくるだけで静止ページを切り出す",
            "入力はライブカメラのみで映像は保存せずメモリ内の画像だけを扱う設計になっている",
            "画像層は正解であり図表やレイアウトや崩れた箇所の確認に使うための高解像度の写真",
            "テキスト層は索引であり検索や要約や横断参照のために低コストで読めるようにしてある",
            "逐語引用が必要なときはテキスト層を信用せず該当ページを画像として読んで原文を確認",
            "図表はテキスト層では読めずラベルの羅列になるので図の内容が必要なときだけ画像を見る",
            "テキスト量が極端に少ないページは撮影不良の可能性が高いので画像で確認して撮り直す",
            "一ファイルは三十メガバイト未満かつ百ページ未満に収め超える章は節の切れ目で分割する",
            "分割は再エンコードなしで行い画質劣化ゼロでテキスト層も保持したままページを移送する",
            "蔵書は私的複製の範囲なので共有してよいのは要約やスライドなどの派生ナレッジだけである",
            "書き出しの既定値はグレースケールである",
            "章を渡して咀嚼したりスライドの下調べをしたり将来は複数冊を横断検索することを想定する",
            "OCRは縮小前のフル解像度で実行してから縮小することで認識精度を落とさずに容量を下げる",
        ]
        // 実機で観測した各行の bbox 高さ(pt, 819pt 高のページ) と x 開始位置(pt, 1152pt 幅)
        let heights: [CGFloat] = [48.3, 45.9, 43.6, 45.3, 47.9, 48.1, 50.0, 49.2, 50.9, 50.4, 28.1, 51.6, 52.9]
        let xs: [CGFloat] = [640, 627, 629, 629, 642, 629, 629, 629, 629, 629, 629, 641, 630]
        let lines = texts.enumerated().map { i, t -> TextLine in
            let w: CGFloat = i == 10 ? 220 : 470
            let y = 359 - CGFloat(i) * 23.5
            return TextLine(text: t,
                            boundingBox: CGRect(x: xs[i] / 1152, y: y / 819, width: w / 1152, height: heights[i] / 819),
                            confidence: 0.9)
        }
        let data = try PDFExporter.pdfData(exportPages: [ExportPage(image: img, textLines: lines)], settings: ExportSettings())
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(doc.page(at: 0)?.string)
        var last = text.startIndex
        for t in texts {
            let key = String(t.prefix(8))
            let range = try XCTUnwrap(text.range(of: key, range: last..<text.endIndex), "「\(key)…」が順番どおりに現れない:\n\(text)")
            last = range.upperBound
        }
        // 検索ヒット位置が元の bbox とおおよそ一致する(3 行目)
        let hits = doc.findString("画像層は正解", withOptions: [])
        let sel = try XCTUnwrap(hits.first)
        let page = try XCTUnwrap(sel.pages.first)
        let b = sel.bounds(for: page)
        let ph = page.bounds(for: .mediaBox).height
        XCTAssertEqual(b.midY / ph, (359 - 2 * 23.5 + 43.6 / 2) / 819, accuracy: 0.03, "hit y=\(b)")
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try PDFExporter.pdfData(pages: [], settings: ExportSettings()))
    }
}
