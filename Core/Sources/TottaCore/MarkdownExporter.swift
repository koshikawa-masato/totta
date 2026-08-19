import Foundation
import CoreGraphics

/// OCR 結果を読みやすい Markdown に組み直す。
///
/// Vision は行を検出順に返すため、そのままつなぐと段組みや縦組みで順序が崩れる。
/// 行の位置から読み順に並べ替え、文末で切れていない行は 1 つの段落にまとめる。
public enum MarkdownExporter {

    /// 1 ページ分のテキスト
    public static func page(from lines: [TextLine]) -> String {
        guard !lines.isEmpty else { return "" }
        // 本文行の幅の目安。図のラベルなど短い行が多いと中央値は小さくなりすぎるので上位側をとる
        let widths = lines.map(\.boundingBox.width).sorted()
        let heights = lines.map(\.boundingBox.height).sorted()
        let bodyWidth = widths[min(widths.count - 1, Int(Double(widths.count) * 0.7))]
        let medianHeight = heights[heights.count / 2]

        var paragraphs: [String] = []
        for block in blocks(lines) {
            var current = ""
            var previous: TextLine? = nil
            for line in block {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if current.isEmpty {
                    current = text
                } else if shouldBreak(after: previous, before: line,
                                      currentText: current,
                                      bodyWidth: bodyWidth, medianHeight: medianHeight) {
                    paragraphs.append(current)
                    current = text
                } else {
                    current += joiner(between: current, and: text)
                    current += text
                }
                previous = line
            }
            if !current.isEmpty { paragraphs.append(current) }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 前の行で段落を切るか
    static func shouldBreak(after previous: TextLine?, before next: TextLine,
                            currentText: String, bodyWidth: CGFloat, medianHeight: CGFloat) -> Bool {
        // 文末で終わっている
        if endsSentence(currentText) { return true }
        guard let previous else { return false }
        // 前の行が本文より明らかに短い(段落の最終行・見出し・図のラベル)
        if previous.boundingBox.width < bodyWidth * 0.7 { return true }
        // 行間が大きく空いている
        let gap = previous.boundingBox.minY - next.boundingBox.maxY
        if gap > medianHeight * 1.2 { return true }
        return false
    }

    /// ページ本文をまとめて 1 つの Markdown にする。
    ///
    /// RAG(Foundry の file search など)に PDF と一緒に投入する前提で、各ページ見出しに
    /// 対応する PDF ファイル名とページ番号を入れる。検索結果の引用から、正解である
    /// PDF のページ画像へ辿れるようにするため。`source` は PDF のファイル名(例 "第2章.pdf")。
    public static func document(title: String?, pages: [String], generatedAt: Date? = nil,
                                source: String? = nil) -> String {
        var out = ""
        if let title, !title.isEmpty {
            out += "# \(title)\n\n"
        }
        if let source, !source.isEmpty {
            out += "_出典 PDF: \(source)(全 \(pages.count) ページ。見出しの p.N は同 PDF のページ番号)_\n\n"
        }
        if let generatedAt {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            out += "_totta でスキャン・OCR (\(f.string(from: generatedAt)))_\n\n"
        }
        for (i, text) in pages.enumerated() {
            if let source, !source.isEmpty {
                out += "## p.\(i + 1) — \(source) p.\(i + 1)\n\n"
            } else {
                out += "## p.\(i + 1)\n\n"
            }
            out += text.isEmpty ? "_(テキストを認識できませんでした)_\n\n" : text + "\n\n"
        }
        return out
    }

    // MARK: - 読み順(レイアウト解析)

    /// 行を読み順に並べ替える。
    ///
    /// 単純に上から下へ並べると、2 段組や「蛇足」のような囲み記事が行単位で混ざってしまう。
    /// そこで XY-cut(余白の切れ目で縦・横に再帰的に分割する古典的な手法)でブロックに分け、
    /// ブロックごとにまとめて読む。
    static func readingOrder(_ lines: [TextLine]) -> [TextLine] {
        blocks(lines).flatMap { $0 }
    }

    /// 読み順に並べたブロック(段・囲み記事など)の列
    static func blocks(_ lines: [TextLine]) -> [[TextLine]] {
        guard lines.count > 1 else { return lines.isEmpty ? [] : [lines] }
        let verticalCount = lines.filter { $0.boundingBox.height > $0.boundingBox.width * 1.5 }.count
        let isVertical = verticalCount * 2 > lines.count
        return xyCut(lines, rightToLeft: isVertical, depth: 0)
    }

    /// 余白の切れ目で再帰的に分割する
    private static func xyCut(_ lines: [TextLine], rightToLeft: Bool, depth: Int) -> [[TextLine]] {
        if lines.count <= 2 || depth >= 6 { return [leaf(lines, rightToLeft: rightToLeft)] }

        let xGap = widestGap(lines.map { ($0.boundingBox.minX, $0.boundingBox.maxX) })
        let yGap = widestGap(lines.map { ($0.boundingBox.minY, $0.boundingBox.maxY) })

        // 段の切れ目(縦の余白)は 2.5% 以上、段落の切れ目(横の余白)は 2% 以上を目安にする
        let xOK = (xGap?.size ?? 0) >= 0.025
        let yOK = (yGap?.size ?? 0) >= 0.02

        if xOK, (xGap?.size ?? 0) >= (yGap?.size ?? 0) {
            let mid = xGap!.center
            let a = lines.filter { $0.boundingBox.midX < mid }
            let b = lines.filter { $0.boundingBox.midX >= mid }
            if a.count >= 1, b.count >= 1 {
                let first = rightToLeft ? b : a      // 縦組みは右の段から読む
                let second = rightToLeft ? a : b
                return xyCut(first, rightToLeft: rightToLeft, depth: depth + 1)
                     + xyCut(second, rightToLeft: rightToLeft, depth: depth + 1)
            }
        }
        if yOK {
            let mid = yGap!.center
            // Vision の y は下が 0 なので、上のブロックは midY が大きい方
            let top = lines.filter { $0.boundingBox.midY >= mid }
            let bottom = lines.filter { $0.boundingBox.midY < mid }
            if top.count >= 1, bottom.count >= 1 {
                return xyCut(top, rightToLeft: rightToLeft, depth: depth + 1)
                     + xyCut(bottom, rightToLeft: rightToLeft, depth: depth + 1)
            }
        }
        return [leaf(lines, rightToLeft: rightToLeft)]
    }

    /// これ以上分割しないブロックの中の並び
    private static func leaf(_ lines: [TextLine], rightToLeft: Bool) -> [TextLine] {
        if rightToLeft {
            return lines.sorted { a, b in
                let ax = a.boundingBox.midX, bx = b.boundingBox.midX
                if abs(ax - bx) > 0.02 { return ax > bx }
                return a.boundingBox.midY > b.boundingBox.midY
            }
        }
        return lines.sorted { a, b in
            let ay = a.boundingBox.midY, by = b.boundingBox.midY
            if abs(ay - by) > 0.01 { return ay > by }
            return a.boundingBox.midX < b.boundingBox.midX
        }
    }

    /// 区間の集合の中で、いちばん広い「どこにも覆われていない隙間」を返す
    static func widestGap(_ intervals: [(CGFloat, CGFloat)]) -> (center: CGFloat, size: CGFloat)? {
        guard intervals.count > 1 else { return nil }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var best: (center: CGFloat, size: CGFloat)? = nil
        var reach = sorted[0].1
        for iv in sorted.dropFirst() {
            if iv.0 > reach {
                let size = iv.0 - reach
                if size > (best?.size ?? 0) { best = ((reach + iv.0) / 2, size) }
            }
            reach = max(reach, iv.1)
        }
        return best
    }

    // MARK: - 段落の組み立て

    /// 文末で終わっているか(次の行と結合しないか)
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        // 「」や括弧は文中でもよく使われるので、文末とみなさない
        return "。．.!?！？".contains(last)
    }

    /// 行をつなぐときの区切り。日本語同士は詰めて、英単語同士は空白を入れる
    static func joiner(between previous: String, and next: String) -> String {
        func isLatinEdge(_ ch: Character?) -> Bool {
            guard let ch else { return false }
            return ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII
        }
        if isLatinEdge(previous.last), isLatinEdge(next.first) { return " " }
        return ""
    }
}
