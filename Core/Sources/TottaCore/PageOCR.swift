import Foundation
import CoreGraphics
import Vision

/// OCR で認識した 1 行
public struct TextLine: Sendable, Equatable {
    public let text: String
    /// 画像に対する正規化座標(原点左下、Vision と同じ)
    public let boundingBox: CGRect
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public struct OCRSettings: Equatable, Sendable {
    public var enabled: Bool = true
    /// 認識言語(優先順)。日本語 + 英語が既定
    public var languages: [String] = ["ja-JP", "en-US"]
    /// これ未満の信頼度の行は捨てる
    public var minimumConfidence: Float = 0.3
    public init() {}
}

/// Vision によるオンデバイス OCR。画像は端末外に出ない。
public enum PageOCR {
    public static func recognize(_ image: CGImage, settings: OCRSettings) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = settings.languages
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= settings.minimumConfidence else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextLine(text: text, boundingBox: obs.boundingBox, confidence: top.confidence)
        }
    }

    /// 対応言語の一覧(デバッグ・設定 UI 用)
    public static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }
}
