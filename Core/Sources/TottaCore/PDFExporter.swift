import Foundation
import CoreGraphics
import CoreText

public enum ExportError: Error, LocalizedError {
    case contextFailed
    case noPages
    public var errorDescription: String? {
        switch self {
        case .contextFailed: return "PDF の生成に失敗しました"
        case .noPages: return "書き出すページがありません"
        }
    }
}

/// PDF に載せる 1 ページ分(画像 + 透明テキスト用の OCR 結果)
public struct ExportPage: Sendable {
    public let image: CGImage
    public let textLines: [TextLine]

    public init(image: CGImage, textLines: [TextLine] = []) {
        self.image = image
        self.textLines = textLines
    }
}

/// PDF を 1 ページずつ書き足していくビルダー。
/// 全ページを同時にメモリへ展開しないので、100 ページを超えるスキャンでもメモリが増えない。
public final class PDFBuilder {
    private let data = NSMutableData()
    private let context: CGContext
    private let settings: ExportSettings
    public private(set) var pageCount = 0
    private var closed = false

    public init(settings: ExportSettings) throws {
        self.settings = settings
        guard let consumer = CGDataConsumer(data: data) else { throw ExportError.contextFailed }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        var meta: [CFString: Any] = [kCGPDFContextCreator: "totta"]
        if let title = settings.title { meta[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, meta as CFDictionary) else {
            throw ExportError.contextFailed
        }
        context = ctx
    }

    /// 1 ページ追加する。画像はここで JPEG に再エンコードされ、呼び出し側は破棄してよい。
    public func add(_ page: ExportPage) {
        guard !closed else { return }
        let img = page.image
        let imageSize = CGSize(width: img.width, height: img.height)
        // JPEG に再エンコードしてから描画すると、Quartz が JPEG ストリームをそのまま埋め込むのでサイズが抑えられる
        let drawImage = ImageUtils.jpegData(img, quality: settings.jpegQuality)
            .flatMap(ImageUtils.image(fromEncoded:)) ?? img

        var box: CGRect
        var drawRect: CGRect
        if let paper = settings.paperSize.points(for: imageSize) {
            box = CGRect(origin: .zero, size: paper)
            // 用紙に収まるよう縦横比を保って中央に配置
            let scale = min(paper.width / imageSize.width, paper.height / imageSize.height)
            let w = imageSize.width * scale, h = imageSize.height * scale
            drawRect = CGRect(x: (paper.width - w) / 2, y: (paper.height - h) / 2, width: w, height: h)
        } else {
            let scale = 72.0 / max(1, settings.dpi)
            box = CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
            drawRect = box
        }
        let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.interpolationQuality = .high
        context.draw(drawImage, in: drawRect)
        if !page.textLines.isEmpty {
            PDFExporter.drawInvisibleText(page.textLines, in: drawRect, context: context)
        }
        context.endPDFPage()
        pageCount += 1
    }

    /// PDF を閉じてデータを返す
    public func finish() throws -> Data {
        guard !closed else { return data as Data }
        guard pageCount > 0 else { throw ExportError.noPages }
        context.closePDF()
        closed = true
        return data as Data
    }
}

public enum PDFExporter {
    /// 見開き画像を左右に分割。縦長(片ページ)の画像は分割せずそのまま返す
    public static func splitSpread(_ image: CGImage, rightToLeft: Bool) -> [CGImage] {
        guard image.width > image.height else { return [image] }
        let half = image.width / 2
        guard half > 0,
              let left = image.cropping(to: CGRect(x: 0, y: 0, width: half, height: image.height)),
              let right = image.cropping(to: CGRect(x: half, y: 0, width: image.width - half, height: image.height))
        else { return [image] }
        return rightToLeft ? [right, left] : [left, right]
    }

    /// 画像だけの PDF(互換 API)。分割設定はここで適用される。
    public static func pdfData(pages: [CGImage], settings: ExportSettings) throws -> Data {
        var expanded: [ExportPage] = []
        for page in pages {
            let images = settings.splitSpread ? splitSpread(page, rightToLeft: settings.rightToLeft) : [page]
            expanded.append(contentsOf: images.map { ExportPage(image: $0) })
        }
        return try pdfData(exportPages: expanded, settings: settings)
    }

    /// 分割済み・OCR 済みのページ列から PDF を作る。各ページに透明テキストを重ねて検索可能にする。
    public static func pdfData(exportPages: [ExportPage], settings: ExportSettings) throws -> Data {
        guard !exportPages.isEmpty else { throw ExportError.noPages }
        let builder = try PDFBuilder(settings: settings)
        for page in exportPages { builder.add(page) }
        return try builder.finish()
    }

    /// OCR 結果を透明テキストとして描く(検索・コピー用)。
    /// 各行を認識位置に合わせ、行の幅に収まるよう横方向にスケールする。
    ///
    /// フォントサイズは Vision の行 bbox の高さから決めるが、写真の傾きで bbox は実際の文字より
    /// 縦に膨らむ(500pt 幅の行が 3° 傾くだけで +26pt)。そのまま使うと隣接行のグリフが縦に重なり、
    /// PDFKit(プレビュー / Spotlight / `page.string`)が段落を 1 ブロックに誤統合して行順を入れ替える。
    /// そこで (1) 隣接行との行ピッチ、(2) 行幅に収まる自然幅、の両方でフォントサイズを抑える。
    /// (2026-08-16 以前の書き出しはこの対策なし。pdfminer 等ストリーム順で読むツールでは元々問題ない)
    static func drawInvisibleText(_ lines: [TextLine], in box: CGRect, context ctx: CGContext) {
        let rects: [CGRect] = lines.map { line in
            CGRect(x: box.minX + line.boundingBox.minX * box.width,
                   y: box.minY + line.boundingBox.minY * box.height,
                   width: line.boundingBox.width * box.width,
                   height: line.boundingBox.height * box.height)
        }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for (i, line) in lines.enumerated() {
            let r = rects[i]
            guard r.width > 0.5, r.height > 0.5 else { continue }
            let vertical = r.height > r.width * 1.5 && line.text.count > 1
            // 行の太さ方向の寸法(横書きなら高さ、縦書きなら幅)。隣接行とのピッチで上限を掛ける
            let thickness = vertical ? r.width : r.height
            let pitch = neighborPitch(of: i, in: rects, vertical: vertical)
            var fontSize = max(1, min(thickness * 0.9, pitch * 0.8))
            var ctLine = makeLine(line.text, fontSize: fontSize)
            var natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            // 行の長さ方向に収まらない(圧縮が必要な)場合はフォントを縮めて自然幅に合わせる
            let extent = vertical ? r.height : r.width
            if natural > extent {
                fontSize = max(1, fontSize * extent / natural)
                ctLine = makeLine(line.text, fontSize: fontSize)
                natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                guard natural > 0 else { continue }
            }
            ctx.saveGState()
            if vertical {
                // 縦書き行: 90° 回転して上から下へ
                let sx = r.height / natural
                ctx.translateBy(x: r.maxX, y: r.maxY)
                ctx.rotate(by: -.pi / 2)
                ctx.scaleBy(x: sx, y: 1)
                ctx.textPosition = CGPoint(x: 0, y: (r.width - fontSize) / 2 + fontSize * 0.2)
            } else {
                let sx = r.width / natural
                ctx.translateBy(x: r.minX, y: r.minY)
                ctx.scaleBy(x: sx, y: 1)
                // グリフ(≈ fontSize 角)を bbox の縦中央に置く。0.2em はおおよそのディセント分
                ctx.textPosition = CGPoint(x: 0, y: (r.height - fontSize) / 2 + fontSize * 0.2)
            }
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private static func makeLine(_ text: String, fontSize: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr: [CFString: Any] = [kCTFontAttributeName: font]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attr as CFDictionary)!
        return CTLineCreateWithAttributedString(attributed)
    }

    /// 行 i と、長さ方向で重なる最も近い隣接行との中心間距離(行ピッチ)。隣接行がなければ無限大。
    private static func neighborPitch(of i: Int, in rects: [CGRect], vertical: Bool) -> CGFloat {
        let r = rects[i]
        var best = CGFloat.greatestFiniteMagnitude
        for (j, o) in rects.enumerated() where j != i {
            if vertical {
                // 縦書き: 縦方向に重なる行同士の x 中心距離
                guard min(r.maxY, o.maxY) - max(r.minY, o.minY) > min(r.height, o.height) * 0.3 else { continue }
                best = min(best, abs(r.midX - o.midX))
            } else {
                guard min(r.maxX, o.maxX) - max(r.minX, o.minX) > min(r.width, o.width) * 0.3 else { continue }
                best = min(best, abs(r.midY - o.midY))
            }
        }
        return best
    }

    public static func write(pages: [CGImage], to url: URL, settings: ExportSettings) throws {
        let data = try pdfData(pages: pages, settings: settings)
        try data.write(to: url, options: .atomic)
    }
}
