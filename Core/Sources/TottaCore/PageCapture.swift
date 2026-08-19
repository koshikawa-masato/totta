import Foundation
import CoreGraphics

/// フレーム画像 1 枚からページ情報を作る処理。ライブカメラの取り込み時に使う。
public enum PageCapture {
    /// フレーム画像から枠を検出して CapturedPage を作る。基準枠があれば検出せずにそれを使う
    public static func makePage(from frame: CGImage, at time: Double, settings: AnalysisSettings,
                                kind: PageSource, stillDuration: Double? = nil,
                                template: FrameTemplate? = nil) -> CapturedPage {
        let size = CGSize(width: frame.width, height: frame.height)
        if let template, template.matchesAspect(of: size) {
            return CapturedPage(time: time, frameSize: size,
                                quad: template.quad(for: size).clamped(to: size),
                                spine: template.spine(for: size)?.clamped(to: size),
                                source: kind, confidence: nil, stillDuration: stillDuration, usedTemplate: true)
        }
        let detected: DetectedPage? = settings.detectPages
            ? ((try? PageDetector.detect(in: frame, minimumSize: settings.minimumPageSize)) ?? nil)
            : nil
        let quad = detected?.quad ?? Quad.fullFrame(size)
        return CapturedPage(time: time, frameSize: size, quad: quad, spine: detected?.spine, source: kind,
                            confidence: detected?.confidence, stillDuration: stillDuration)
    }

    /// 重複判定用の指紋。枠で切り出した画像(失敗時はフレーム全体)を固定サイズに縮小して比較する。
    public static func pageFingerprint(frame: CGImage, quad: Quad, spine: Spine? = nil) -> Fingerprint {
        let cropped = (try? PageDetector.crop(frame, to: quad, spine: spine)) ?? frame
        return Fingerprint.pageFingerprint(cropped)
    }
}

/// 取り込んだページ列に対する重複判定の状態。直前に採用したページの指紋を覚えておく。
public struct DuplicateFilter: Sendable {
    private var lastKept: Fingerprint?
    public init() {}

    public mutating func reset() { lastKept = nil }

    /// - Returns: (採用すべきか, 直前ページとの差)
    public mutating func evaluate(_ fingerprint: Fingerprint, threshold: Float, force: Bool = false) -> (keep: Bool, difference: Float?) {
        var diff: Float? = nil
        if let last = lastKept {
            let d = fingerprint.distance(to: last)
            diff = d
            if !force, threshold > 0, d < threshold { return (false, diff) }
        }
        lastKept = fingerprint
        return (true, diff)
    }
}
