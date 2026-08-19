import Foundation
import CoreGraphics

/// PDF に載せる 1 見開き分の入力。画像は JPEG のまま渡し、必要になったときだけ展開する。
public struct ExportJob: Sendable {
    /// 取り込んだフレーム(JPEG)
    public let frameJPEG: Data
    /// 切り出し枠・のど線を持つページ情報
    public let page: CapturedPage

    public init(frameJPEG: Data, page: CapturedPage) {
        self.frameJPEG = frameJPEG
        self.page = page
    }
}

/// 書き出し結果。PDF と、OCR したテキスト(Markdown)を返す。
public struct ExportOutput: Sendable {
    public let pdf: Data
    /// PDF のページごとのテキスト(OCR オフなら空文字)
    public let pageTexts: [String]

    public init(pdf: Data, pageTexts: [String]) {
        self.pdf = pdf
        self.pageTexts = pageTexts
    }

    public var hasText: Bool { pageTexts.contains { !$0.isEmpty } }

    /// Markdown 文書に組み立てる。`source` は対応する PDF のファイル名(引用からページ画像へ辿るための手がかり)
    public func markdown(title: String?, generatedAt: Date? = nil, source: String? = nil) -> String {
        MarkdownExporter.document(title: title, pages: pageTexts, generatedAt: generatedAt, source: source)
    }
}

public struct ExportProgress: Sendable {
    /// 0...1
    public let fraction: Double
    public let message: String
}

public enum PDFPipeline {
    /// 取り込んだページ列から検索できる PDF を作る。
    ///
    /// 1 ページずつ「展開 → 切り出し → 補正 → 見開き分割 → OCR → PDF に追記」を行い、
    /// 終わったページの画像はその都度捨てるので、ページ数が増えてもメモリ使用量はほぼ一定。
    /// `Task.isCancelled` を見ているので、呼び出し側の Task をキャンセルすれば途中で止まる。
    public static func build(jobs: [ExportJob],
                             enhance: EnhanceSettings,
                             ocr: OCRSettings,
                             export: ExportSettings,
                             progress: (@Sendable (ExportProgress) -> Void)? = nil) throws -> ExportOutput {
        guard !jobs.isEmpty else { throw ExportError.noPages }
        let builder = try PDFBuilder(settings: export)
        let total = Double(jobs.count)
        var pageTexts: [String] = []

        for (i, job) in jobs.enumerated() {
            try Task.checkCancellation()
            let base = Double(i) / total
            let step = 1 / total
            // 1 ページ分の一時画像(展開したフレーム・切り出し・補正結果)をその都度解放する。
            // これを外すと CoreGraphics の一時オブジェクトが溜まり、ページ数に比例してメモリが増える。
            try autoreleasepool {
                progress?(ExportProgress(fraction: base, message: "ページ \(i + 1)/\(jobs.count): 読み込み中…"))

                guard let frame = ImageUtils.image(fromEncoded: job.frameJPEG) else { return }
                let cropped = try PageDetector.crop(frame, to: job.page.quad, spine: job.page.spine)

                progress?(ExportProgress(fraction: base + step * 0.3, message: "ページ \(i + 1)/\(jobs.count): 補正中…"))
                let enhanced = try PageEnhancer.enhance(cropped, settings: enhance).image

                let images = export.splitSpread
                    ? PDFExporter.splitSpread(enhanced, rightToLeft: export.rightToLeft)
                    : [enhanced]

                for (k, image) in images.enumerated() {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        var lines: [TextLine] = []
                        if ocr.enabled {
                            progress?(ExportProgress(fraction: base + step * (0.5 + 0.3 * Double(k) / Double(images.count)),
                                                     message: "ページ \(i + 1)/\(jobs.count): OCR 中…"))
                            lines = (try? PageOCR.recognize(image, settings: ocr)) ?? []
                        }
                        // OCR はフル解像度で終えてから縮小する(認識精度を落とさずサイズだけ下げる)
                        let output = export.maxPageDimension
                            .map { ImageUtils.resized(image, maxDimension: CGFloat($0)) } ?? image
                        builder.add(ExportPage(image: output, textLines: lines))
                        pageTexts.append(MarkdownExporter.page(from: lines))
                    }
                }
                progress?(ExportProgress(fraction: base + step, message: "ページ \(i + 1)/\(jobs.count): 完了"))
            }
            // CoreImage のテクスチャキャッシュはページをまたいで増えるので、都度解放する
            PageEnhancer.clearCaches()
            PageDetector.clearCaches()
        }

        try Task.checkCancellation()
        progress?(ExportProgress(fraction: 1, message: "PDF を書き出し中…"))
        return ExportOutput(pdf: try builder.finish(), pageTexts: pageTexts)
    }
}
