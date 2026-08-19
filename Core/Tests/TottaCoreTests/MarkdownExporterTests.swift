import XCTest
@testable import TottaCore

final class MarkdownExporterTests: XCTestCase {
    /// Vision と同じ正規化座標(原点左下)で行を作る
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.4, h: CGFloat = 0.03) -> TextLine {
        TextLine(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h), confidence: 0.9)
    }

    func testHorizontalReadingOrder() {
        // 検出順はばらばら。上から下・左から右に並べ直す
        let lines = [line("三行目", x: 0.1, y: 0.5),
                     line("一行目", x: 0.1, y: 0.9),
                     line("右上", x: 0.6, y: 0.9),
                     line("二行目", x: 0.1, y: 0.7)]
        let sorted = MarkdownExporter.readingOrder(lines).map(\.text)
        XCTAssertEqual(sorted, ["一行目", "右上", "二行目", "三行目"])
    }

    func testVerticalReadingOrderRightToLeft() {
        // 縦組み: 縦長の行が並ぶ。右の列から左へ
        func col(_ t: String, x: CGFloat, y: CGFloat) -> TextLine {
            TextLine(text: t, boundingBox: CGRect(x: x, y: y, width: 0.04, height: 0.5), confidence: 0.9)
        }
        let lines = [col("左の列", x: 0.2, y: 0.3), col("右の列", x: 0.8, y: 0.3), col("右の列の下", x: 0.8, y: 0.05)]
        let sorted = MarkdownExporter.readingOrder(lines).map(\.text)
        XCTAssertEqual(sorted, ["右の列", "右の列の下", "左の列"])
    }

    func testParagraphsJoinUntilSentenceEnd() {
        let lines = [line("これは長い文章の", x: 0.1, y: 0.9),
                     line("途中で折り返した行である。", x: 0.1, y: 0.86),
                     line("次の段落が始まる。", x: 0.1, y: 0.80)]
        let md = MarkdownExporter.page(from: lines)
        XCTAssertEqual(md, "これは長い文章の途中で折り返した行である。\n\n次の段落が始まる。")
    }

    func testEnglishLinesJoinWithSpace() {
        let lines = [line("This is a wrapped", x: 0.1, y: 0.9),
                     line("English sentence.", x: 0.1, y: 0.86)]
        XCTAssertEqual(MarkdownExporter.page(from: lines), "This is a wrapped English sentence.")
    }

    func testDocumentStructure() {
        let md = MarkdownExporter.document(title: "技術の創造と設計", pages: ["本文A。", "", "本文C。"])
        XCTAssertTrue(md.hasPrefix("# 技術の創造と設計"))
        XCTAssertTrue(md.contains("## p.1\n\n本文A。"))
        XCTAssertTrue(md.contains("## p.2\n\n_(テキストを認識できませんでした)_"))
        XCTAssertTrue(md.contains("## p.3\n\n本文C。"))
        XCTAssertFalse(md.contains("出典 PDF"))
    }

    /// RAG 用: 各ページ見出しに対応 PDF 名とページ番号が入り、引用から PDF ページへ辿れる
    func testDocumentCarriesSourcePDFPerPage() {
        let md = MarkdownExporter.document(title: "技術の創造と設計 第2章", pages: ["本文A。", "本文B。"],
                                           source: "技術の創造と設計_畑村洋太郎_第2章.pdf")
        XCTAssertTrue(md.contains("_出典 PDF: 技術の創造と設計_畑村洋太郎_第2章.pdf(全 2 ページ"))
        XCTAssertTrue(md.contains("## p.1 — 技術の創造と設計_畑村洋太郎_第2章.pdf p.1\n\n本文A。"))
        XCTAssertTrue(md.contains("## p.2 — 技術の創造と設計_畑村洋太郎_第2章.pdf p.2\n\n本文B。"))
    }

    /// 2 段組が行単位で混ざらないこと(左段を全部読んでから右段)
    func testTwoColumnLayoutIsNotInterleaved() {
        var lines: [TextLine] = []
        for i in 0..<6 {
            let y = 0.90 - CGFloat(i) * 0.06
            lines.append(line("左\(i)", x: 0.05, y: y, w: 0.38))
            lines.append(line("右\(i)", x: 0.55, y: y, w: 0.38))
        }
        let order = MarkdownExporter.readingOrder(lines).map(\.text)
        XCTAssertEqual(order, ["左0","左1","左2","左3","左4","左5","右0","右1","右2","右3","右4","右5"],
                       "段組が混ざっている: \(order)")
    }

    /// 見出し(本文より短い行)は独立した段落になる
    func testShortLineStartsNewParagraph() {
        let lines = [line("1.1 見出し", x: 0.05, y: 0.90, w: 0.15),
                     line("本文の一行目が続いて", x: 0.05, y: 0.85, w: 0.40),
                     line("二行目もつながる", x: 0.05, y: 0.81, w: 0.40)]
        let md = MarkdownExporter.page(from: lines)
        XCTAssertEqual(md, "1.1 見出し\n\n本文の一行目が続いて二行目もつながる")
    }

    /// 鉤括弧で終わる行は文末とみなさない(文中の引用でよく使われるため)
    func testQuoteBracketIsNotSentenceEnd() {
        XCTAssertFalse(MarkdownExporter.endsSentence("生産量が少ない「萌芽期」"))
        XCTAssertTrue(MarkdownExporter.endsSentence("約30年になっているのである。"))
    }

    func testWidestGapFindsColumnGutter() {
        let gap = MarkdownExporter.widestGap([(0.05, 0.43), (0.05, 0.42), (0.55, 0.93), (0.56, 0.93)])
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap!.center, 0.49, accuracy: 0.01)
        XCTAssertEqual(gap!.size, 0.12, accuracy: 0.01)
    }

    func testEmptyPage() {
        XCTAssertEqual(MarkdownExporter.page(from: []), "")
    }
}
