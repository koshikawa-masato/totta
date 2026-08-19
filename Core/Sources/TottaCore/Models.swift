import Foundation
import CoreGraphics

/// 画像ピクセル座標系(左上原点)の四角形。ページ領域の指定に使う。
public struct Quad: Equatable, Hashable, Codable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public init(rect: CGRect) {
        topLeft = CGPoint(x: rect.minX, y: rect.minY)
        topRight = CGPoint(x: rect.maxX, y: rect.minY)
        bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
    }

    public static func fullFrame(_ size: CGSize) -> Quad {
        Quad(rect: CGRect(origin: .zero, size: size))
    }

    public enum Corner: CaseIterable, Sendable, Hashable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    public subscript(corner: Corner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }

    /// TL, TR, BR, BL の順
    public var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public var boundingBox: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// 靴紐公式による面積
    public var area: CGFloat {
        let p = points
        var s: CGFloat = 0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// 台形補正後のおおよそのサイズ
    public var correctedSize: CGSize {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let w = (d(topLeft, topRight) + d(bottomLeft, bottomRight)) / 2
        let h = (d(topLeft, bottomLeft) + d(topRight, bottomRight)) / 2
        return CGSize(width: w, height: h)
    }

    public var isValid: Bool {
        let s = correctedSize
        return area > 1 && s.width >= 2 && s.height >= 2
    }

    /// 軸に平行な矩形か(この場合は単純クロップで済む)
    public var isAxisAlignedRect: Bool {
        topLeft.y == topRight.y && bottomLeft.y == bottomRight.y &&
        topLeft.x == bottomLeft.x && topRight.x == bottomRight.x
    }

    public func scaled(_ s: CGFloat) -> Quad { scaled(x: s, y: s) }

    public func scaled(x sx: CGFloat, y sy: CGFloat) -> Quad {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        return Quad(topLeft: m(topLeft), topRight: m(topRight), bottomRight: m(bottomRight), bottomLeft: m(bottomLeft))
    }

    public func scaled(from: CGSize, to: CGSize) -> Quad {
        scaled(x: to.width / from.width, y: to.height / from.height)
    }

    public func translated(by v: CGVector) -> Quad {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
        return Quad(topLeft: m(topLeft), topRight: m(topRight), bottomRight: m(bottomRight), bottomLeft: m(bottomLeft))
    }

    public func clamped(to size: CGSize) -> Quad {
        func c(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height))
        }
        return Quad(topLeft: c(topLeft), topRight: c(topRight), bottomRight: c(bottomRight), bottomLeft: c(bottomLeft))
    }
}

/// 見開きの「のど」(左右ページの境界)。外枠 Quad と組み合わせて左右ページを別々に補正する。
public struct Spine: Equatable, Hashable, Codable, Sendable {
    public var top: CGPoint
    public var bottom: CGPoint
    public init(top: CGPoint, bottom: CGPoint) {
        self.top = top
        self.bottom = bottom
    }
    /// 外枠の上辺・下辺の中点に置いた既定ののど線
    public static func centered(in quad: Quad) -> Spine {
        Spine(top: CGPoint(x: (quad.topLeft.x + quad.topRight.x) / 2, y: (quad.topLeft.y + quad.topRight.y) / 2),
              bottom: CGPoint(x: (quad.bottomLeft.x + quad.bottomRight.x) / 2, y: (quad.bottomLeft.y + quad.bottomRight.y) / 2))
    }
    public func scaled(x sx: CGFloat, y sy: CGFloat) -> Spine {
        Spine(top: CGPoint(x: top.x * sx, y: top.y * sy), bottom: CGPoint(x: bottom.x * sx, y: bottom.y * sy))
    }
    public func scaled(from: CGSize, to: CGSize) -> Spine {
        scaled(x: to.width / from.width, y: to.height / from.height)
    }
    public func translated(by v: CGVector) -> Spine {
        Spine(top: CGPoint(x: top.x + v.dx, y: top.y + v.dy), bottom: CGPoint(x: bottom.x + v.dx, y: bottom.y + v.dy))
    }
    public func clamped(to size: CGSize) -> Spine {
        func c(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height)) }
        return Spine(top: c(top), bottom: c(bottom))
    }
}

extension Quad {
    /// のど線で左右のページに分ける
    public func split(at spine: Spine) -> (left: Quad, right: Quad) {
        (Quad(topLeft: topLeft, topRight: spine.top, bottomRight: spine.bottom, bottomLeft: bottomLeft),
         Quad(topLeft: spine.top, topRight: topRight, bottomRight: bottomRight, bottomLeft: spine.bottom))
    }
}

/// 基準枠: 一度合わせた外枠+のど線を保存し、以降の取り込みに検出なしで適用する
public struct FrameTemplate: Equatable, Hashable, Codable, Sendable {
    public var quad: Quad
    public var spine: Spine?
    /// quad/spine の座標系(取り込みフレームのピクセルサイズ)。フレームサイズが変われば拡縮して使う
    public var frameSize: CGSize

    public init(quad: Quad, spine: Spine?, frameSize: CGSize) {
        self.quad = quad
        self.spine = spine
        self.frameSize = frameSize
    }

    public func quad(for size: CGSize) -> Quad { quad.scaled(from: frameSize, to: size) }
    public func spine(for size: CGSize) -> Spine? { spine?.scaled(from: frameSize, to: size) }

    /// 保存時とフレームの縦横比が近いか。向きが変わった(縦↔横)基準枠を誤って引き伸ばさないための判定。
    public func matchesAspect(of size: CGSize, tolerance: CGFloat = 0.12) -> Bool {
        guard frameSize.width > 0, frameSize.height > 0, size.width > 0, size.height > 0 else { return false }
        let a = frameSize.width / frameSize.height
        let b = size.width / size.height
        return abs(a - b) / max(a, b) <= tolerance
    }
}

public enum PageSource: String, Codable, Sendable {
    case auto
    case manual
}

/// カメラから取り込んだ1見開き分の情報。画像本体は保持せず、時刻と枠だけを持つ。
public struct CapturedPage: Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// 取り込みセッション開始からの時刻(秒)
    public var time: Double
    /// フレームのピクセルサイズ(quad の座標系)
    public var frameSize: CGSize
    public var quad: Quad
    /// 見開きののど線。nil なら quad 全体を 1 枚として補正する
    public var spine: Spine?
    public var isIncluded: Bool
    public var source: PageSource
    /// 自動検出時の信頼度(未検出なら nil)
    public var confidence: Float?
    /// 静止区間の長さ(自動検出時)
    public var stillDuration: Double?
    /// 直前に採用したページとの切り出し画像の差(0-255 平均絶対差)。小さいほど似ている。
    public var differenceFromPrevious: Float?
    /// 基準枠を適用して取り込んだページ
    public var usedTemplate: Bool = false

    public init(id: UUID = UUID(), time: Double, frameSize: CGSize, quad: Quad, spine: Spine? = nil, isIncluded: Bool = true,
                source: PageSource, confidence: Float? = nil, stillDuration: Double? = nil,
                differenceFromPrevious: Float? = nil, usedTemplate: Bool = false) {
        self.id = id
        self.time = time
        self.frameSize = frameSize
        self.quad = quad
        self.spine = spine
        self.isIncluded = isIncluded
        self.source = source
        self.confidence = confidence
        self.stillDuration = stillDuration
        self.differenceFromPrevious = differenceFromPrevious
        self.usedTemplate = usedTemplate
    }
}

/// ページ取り込み(静止判定・枠検出・重複判定)のパラメータ
public struct AnalysisSettings: Equatable, Sendable {
    /// 動き判定に使うフレームの間引き間隔(秒)
    public var samplingInterval: Double = 0.15
    /// これ未満の平均輝度差なら「静止」とみなす(0-255)
    public var motionThreshold: Float = 3.0
    /// 静止区間として採用する最短時間(秒)
    public var minStillDuration: Double = 0.7
    /// 直前に採用したページと切り出し画像を比較し、これ未満の差なら同一ページとして自動的に捨てる(0 で無効)
    public var duplicateThreshold: Float = 2.0
    /// これ未満の差なら「前ページと酷似」として要確認マークを付ける(UI 用)
    public var similarWarningThreshold: Float = 6.0
    /// 差分解析用の縮小画像の幅(px)
    public var fingerprintWidth: Int = 48
    /// Vision による自動枠検出を行うか
    public var detectPages: Bool = true
    /// 検出する矩形の最小サイズ(画像に対する比率)
    public var minimumPageSize: Float = 0.2

    public init() {}
}

/// PDF のページサイズ
public enum PaperSize: String, CaseIterable, Sendable, Codable {
    /// 画像の画素数と DPI からページサイズを決める(既定)
    case original
    case a4, a5, b5, b6, letter

    public var label: String {
        switch self {
        case .original: return "画像のまま (DPI 基準)"
        case .a4: return "A4"
        case .a5: return "A5"
        case .b5: return "B5 (JIS)"
        case .b6: return "B6 (JIS)"
        case .letter: return "レター"
        }
    }

    /// 縦向きのポイントサイズ(1pt = 1/72 inch)。original は nil
    public var portraitPoints: CGSize? {
        switch self {
        case .original: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .a5: return CGSize(width: 419.53, height: 595.28)
        case .b5: return CGSize(width: 515.91, height: 728.50)   // JIS B5 182×257mm
        case .b6: return CGSize(width: 362.83, height: 515.91)   // JIS B6 128×182mm
        case .letter: return CGSize(width: 612, height: 792)
        }
    }

    /// 画像の縦横に合わせて向きを決めたページサイズ
    public func points(for imageSize: CGSize) -> CGSize? {
        guard let p = portraitPoints else { return nil }
        return imageSize.width > imageSize.height ? CGSize(width: p.height, height: p.width) : p
    }
}

/// PDF 書き出しのパラメータ
public struct ExportSettings: Equatable, Sendable {
    /// 見開きを左右2ページに分割する。
    /// 既定で分割する(2026-08-16〜): 見開きのまま 1 ページにすると、pdfminer など外部パーサのレイアウト解析が
    /// 左右ページの行を交互に混ぜることがある。1 ページ 1 面なら、どのパーサでも左右が混ざる余地がない。
    /// (縦長の画像は分割しない。PDFExporter.splitSpread 参照)
    public var splitSpread: Bool = true
    /// 右綴じ(分割時に右ページを先にする)
    public var rightToLeft: Bool = false
    /// JPEG 品質 (0-1)。スキャン文書は輪郭が主なので、下げても可読性はあまり落ちない
    public var jpegQuality: Double = 0.75
    /// PDF ページサイズ算出用の DPI(paperSize が .original のときに使う)
    public var dpi: Double = 150
    /// 用紙サイズ。.original なら画像の画素数と DPI から決める
    public var paperSize: PaperSize = .original
    /// PDF に載せるページ画像の長辺の上限(px)。nil なら撮影したまま。
    /// OCR は縮小前のフル解像度で行うので、下げても認識精度には影響しない。
    public var maxPageDimension: Int? = 2400
    public var title: String?

    public init() {}
}
