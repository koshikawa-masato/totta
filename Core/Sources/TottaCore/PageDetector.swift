import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

public struct DetectedPage: Sendable, Equatable {
    public let quad: Quad
    public let confidence: Float
    /// 左右 2 ページが別々に見つかって結合した場合ののど線
    public let spine: Spine?

    public init(quad: Quad, confidence: Float, spine: Spine? = nil) {
        self.quad = quad
        self.confidence = confidence
        self.spine = spine
    }
}

public enum PageDetectorError: Error, LocalizedError {
    case cropFailed
    public var errorDescription: String? { "画像の切り出しに失敗しました" }
}

extension DetectedPage {
    func scaledUp(_ s: CGFloat) -> DetectedPage {
        DetectedPage(quad: quad.scaled(s), confidence: confidence, spine: spine?.scaled(x: s, y: s))
    }
}

public enum PageDetector {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// CoreImage が内部に持つテクスチャキャッシュを解放する
    public static func clearCaches() {
        ciContext.clearCaches()
    }

    /// Vision で見開き(または最大のページ矩形)を探す。見つからなければ nil。
    ///
    /// のどで折れた見開きは 1 つの四角形として検出されず、片ページだけが拾われがちなので、
    /// 1. 検出結果の中に左右に隣接するもう 1 ページがあれば結合する
    /// 2. 無ければ、見つかったページを塗りつぶしてもう一度検出し、隣のページを探す
    /// という手順で 2 ページ分の枠(+のど線)を作る。
    public static func detect(in image: CGImage, minimumSize: Float = 0.2, detectionMaxDimension: CGFloat = 1600) throws -> DetectedPage? {
        let work = ImageUtils.resized(image, maxDimension: detectionMaxDimension)
        let scale = CGFloat(image.width) / CGFloat(work.width)
        let imageSize = CGSize(width: image.width, height: image.height)
        let frameW = imageSize.width
        // ページ 1 枚は見開きの半分なので、最小サイズは少し緩める
        let candidates = try rectangles(in: work, minimumSize: max(0.08, minimumSize * 0.5)).map { $0.scaledUp(scale) }
        let first = candidates.max(by: { $0.quad.area < $1.quad.area })

        if let first {
            // 1. 検出結果の中に隣のページがあれば結合
            if let partner = neighbor(of: first, among: candidates, frameWidth: frameW) {
                return merge(first, partner)
            }
            // 2. 見つかったページを消してもう一度探す
            let bb = first.quad.boundingBox
            if bb.width < frameW * 0.6,
               let masked = masking(work, rect: bb.insetBy(dx: -bb.width * 0.03, dy: -bb.height * 0.03)
                                        .applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))) {
                let second = try rectangles(in: masked, minimumSize: max(0.08, minimumSize * 0.5)).map { $0.scaledUp(scale) }
                if let partner = neighbor(of: first, among: second, frameWidth: frameW) {
                    return merge(first, partner)
                }
            }
        }

        // 3. 書類セグメンテーション(学習済みモデル)のマスクで見開き全体の外形を補う
        let mask = try? documentMask(in: work, imageSize: imageSize)
        if let first {
            if let mask, let spread = fitSpread(mask: mask, page: first) {
                return spread
            }
            return withCenteredSpineIfWide(first)
        }
        if let mask, let quad = mask.outerQuad(), quad.area > imageSize.width * imageSize.height * 0.1 {
            return withCenteredSpineIfWide(DetectedPage(quad: quad, confidence: mask.confidence * 0.8))
        }
        return nil
    }

    /// 平らな本で見開き全体が 1 つの矩形として取れた場合、横長なら中央にのど線を置く
    /// (左右別補正になり、分割書き出しも正確に半分で割れる。平面なら結果は 1 枚補正と同じ)
    private static func withCenteredSpineIfWide(_ page: DetectedPage) -> DetectedPage {
        guard page.spine == nil else { return page }
        let s = page.quad.correctedSize
        guard s.height > 0, s.width / s.height > 1.2 else { return page }
        return DetectedPage(quad: page.quad, confidence: page.confidence, spine: Spine.centered(in: page.quad))
    }

    // MARK: 書類マスク

    /// 書類セグメンテーションのマスクを、画像座標に対応した粗いグリッドとして持つ
    struct DocumentMask {
        let width: Int
        let height: Int
        let cells: [Bool]        // 最大連結成分のみ
        let cellSize: CGSize     // 1 セルの画像ピクセルサイズ
        let confidence: Float

        subscript(x: Int, y: Int) -> Bool { cells[y * width + x] }
        func point(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: (CGFloat(x) + 0.5) * cellSize.width, y: (CGFloat(y) + 0.5) * cellSize.height)
        }
        var areaPixels: CGFloat {
            CGFloat(cells.reduce(0) { $0 + ($1 ? 1 : 0) }) * cellSize.width * cellSize.height
        }
        var centroid: CGPoint {
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<height { for x in 0..<width where self[x, y] { sx += Double(x); sy += Double(y); n += 1 } }
            guard n > 0 else { return .zero }
            return point(Int(sx / n), Int(sy / n))
        }
        /// 条件を満たすセルの中で、score(p) が最小になる点
        func extreme(where include: (Int, Int) -> Bool, score: (CGPoint) -> CGFloat) -> CGPoint? {
            var best: (CGPoint, CGFloat)? = nil
            for y in 0..<height {
                for x in 0..<width where self[x, y] && include(x, y) {
                    let p = point(x, y)
                    let sc = score(p)
                    if best == nil || sc < best!.1 { best = (p, sc) }
                }
            }
            return best?.0
        }
        /// マスク全体の四隅(左上: x+y 最小、右上: x−y 最大、右下: x+y 最大、左下: x−y 最小)
        func outerQuad() -> Quad? {
            guard let tl = extreme(where: { _, _ in true }, score: { $0.x + $0.y }),
                  let tr = extreme(where: { _, _ in true }, score: { -($0.x - $0.y) }),
                  let br = extreme(where: { _, _ in true }, score: { -($0.x + $0.y) }),
                  let bl = extreme(where: { _, _ in true }, score: { $0.x - $0.y }) else { return nil }
            let q = Quad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
            return q.isValid ? q : nil
        }
    }

    /// VNDetectDocumentSegmentationRequest を実行し、マスクを粗いグリッドにして返す
    static func documentMask(in work: CGImage, imageSize: CGSize, gridWidth: Int = 160) throws -> DocumentMask? {
        let request = VNDetectDocumentSegmentationRequest()
        try VNImageRequestHandler(cgImage: work, options: [:]).perform([request])
        guard let obs = request.results?.first, let maskObs = obs.globalSegmentationMask else { return nil }
        let gw = gridWidth
        let gh = max(1, Int((CGFloat(gw) * imageSize.height / imageSize.width).rounded()))
        // マスク(float の CVPixelBuffer)を CoreImage 経由でグレー 8bit に描き直す
        let ci = CIImage(cvPixelBuffer: maskObs.pixelBuffer)
        guard let maskCG = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        var bytes = [UInt8](repeating: 0, count: gw * gh)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let g = CGContext(data: buf.baseAddress, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            g.interpolationQuality = .medium
            g.draw(maskCG, in: CGRect(x: 0, y: 0, width: gw, height: gh))
            return true
        }
        guard ok else { return nil }
        var on = bytes.map { $0 > 127 }
        // 最大連結成分だけ残す
        var label = [Int32](repeating: -1, count: gw * gh)
        var bestLabel: Int32 = -1, bestCount = 0, comp: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(gw * gh) where on[start] && label[start] < 0 {
            var count = 0
            stack.append(start); label[start] = comp
            while let i = stack.popLast() {
                count += 1
                let x = i % gw, y = i / gw
                if x > 0, on[i - 1], label[i - 1] < 0 { label[i - 1] = comp; stack.append(i - 1) }
                if x < gw - 1, on[i + 1], label[i + 1] < 0 { label[i + 1] = comp; stack.append(i + 1) }
                if y > 0, on[i - gw], label[i - gw] < 0 { label[i - gw] = comp; stack.append(i - gw) }
                if y < gh - 1, on[i + gw], label[i + gw] < 0 { label[i + gw] = comp; stack.append(i + gw) }
            }
            if count > bestCount { bestCount = count; bestLabel = comp }
            comp += 1
        }
        guard bestCount > 0 else { return nil }
        for i in 0..<(gw * gh) { on[i] = label[i] == bestLabel }
        return DocumentMask(width: gw, height: gh, cells: on,
                            cellSize: CGSize(width: imageSize.width / CGFloat(gw), height: imageSize.height / CGFloat(gh)),
                            confidence: obs.confidence)
    }

    /// 片ページの矩形 `page` と書類マスクから、もう片方のページを含む見開き枠を作る。
    /// マスクのうち矩形の内側の辺より外にある領域の 2 隅を、見開きの外側の角として使う。
    static func fitSpread(mask: DocumentMask, page: DetectedPage) -> DetectedPage? {
        let r = page.quad
        let bb = r.boundingBox
        // 矩形がマスクの大半を占めるなら、それが見開き全体
        guard mask.areaPixels > 0, r.area < mask.areaPixels * 0.75 else { return nil }
        let pageIsRight = bb.midX >= mask.centroid.x
        let margin = bb.width * 0.05
        let region: (Int, Int) -> Bool
        let innerTop: CGPoint, innerBottom: CGPoint
        if pageIsRight {
            innerTop = r.topLeft; innerBottom = r.bottomLeft
            let limit = min(innerTop.x, innerBottom.x) - margin
            region = { x, _ in mask.point(x, 0).x < limit }
        } else {
            innerTop = r.topRight; innerBottom = r.bottomRight
            let limit = max(innerTop.x, innerBottom.x) + margin
            region = { x, _ in mask.point(x, 0).x > limit }
        }
        // 残り側の面積が十分あること
        var regionCells = 0
        for y in 0..<mask.height { for x in 0..<mask.width where mask[x, y] && region(x, y) { regionCells += 1 } }
        let regionArea = CGFloat(regionCells) * mask.cellSize.width * mask.cellSize.height
        guard regionArea > r.area * 0.25 else { return nil }

        let outerTop: CGPoint?, outerBottom: CGPoint?
        if pageIsRight {
            outerTop = mask.extreme(where: region, score: { $0.x + $0.y })        // 左上
            outerBottom = mask.extreme(where: region, score: { $0.x - $0.y })     // 左下
        } else {
            outerTop = mask.extreme(where: region, score: { -($0.x - $0.y) })     // 右上
            outerBottom = mask.extreme(where: region, score: { -($0.x + $0.y) })  // 右下
        }
        guard let ot = outerTop, let ob = outerBottom else { return nil }
        // 外側の角は内側の辺から十分離れていること
        let minOffset = bb.width * 0.15
        if pageIsRight {
            guard ot.x < innerTop.x - minOffset, ob.x < innerBottom.x - minOffset else { return nil }
        } else {
            guard ot.x > innerTop.x + minOffset, ob.x > innerBottom.x + minOffset else { return nil }
        }
        let quad = pageIsRight
            ? Quad(topLeft: ot, topRight: r.topRight, bottomRight: r.bottomRight, bottomLeft: ob)
            : Quad(topLeft: r.topLeft, topRight: ot, bottomRight: ob, bottomLeft: r.bottomLeft)
        guard quad.isValid else { return nil }
        return DetectedPage(quad: quad, confidence: page.confidence * 0.9, spine: Spine(top: innerTop, bottom: innerBottom))
    }

    private static func rectangles(in image: CGImage, minimumSize: Float) throws -> [DetectedPage] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = minimumSize
        request.maximumObservations = 12
        request.minimumConfidence = 0.5
        request.quadratureTolerance = 30
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).map { obs in
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }
            let q = Quad(topLeft: pt(obs.topLeft), topRight: pt(obs.topRight),
                         bottomRight: pt(obs.bottomRight), bottomLeft: pt(obs.bottomLeft))
            return DetectedPage(quad: q, confidence: obs.confidence)
        }
    }

    /// `page` の左右どちらかに隣接し、大きさが近い別ページを探す
    private static func neighbor(of page: DetectedPage, among candidates: [DetectedPage], frameWidth: CGFloat) -> DetectedPage? {
        let a = page.quad.boundingBox
        var best: (DetectedPage, CGFloat)? = nil
        for c in candidates where c != page {
            let b = c.quad.boundingBox
            // 面積が近い(0.3〜3 倍)
            let ratio = c.quad.area / max(page.quad.area, 1)
            guard ratio > 0.3, ratio < 3.0 else { continue }
            // 縦方向に十分重なる
            let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            guard vOverlap > 0.5 * min(a.height, b.height) else { continue }
            // 横方向にはほとんど重ならず、隙間も小さい
            let hOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            guard hOverlap < 0.25 * min(a.width, b.width) else { continue }
            let gap = max(0, -hOverlap)
            guard gap < frameWidth * 0.15 else { continue }
            let score = gap + abs(a.midY - b.midY)
            if best == nil || score < best!.1 { best = (c, score) }
        }
        return best?.0
    }

    /// 左右 2 ページを 1 つの見開き枠に結合(のど線は 2 ページの境界の中点)
    private static func merge(_ p: DetectedPage, _ q: DetectedPage) -> DetectedPage {
        let (l, r) = p.quad.boundingBox.midX <= q.quad.boundingBox.midX ? (p, q) : (q, p)
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let spine = Spine(top: mid(l.quad.topRight, r.quad.topLeft), bottom: mid(l.quad.bottomRight, r.quad.bottomLeft))
        let quad = Quad(topLeft: l.quad.topLeft, topRight: r.quad.topRight, bottomRight: r.quad.bottomRight, bottomLeft: l.quad.bottomLeft)
        return DetectedPage(quad: quad, confidence: min(l.confidence, r.confidence), spine: spine)
    }

    /// 指定矩形を黒く塗りつぶした画像
    private static func masking(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        // CG は左下原点なので y を反転
        let flipped = CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)
        ctx.fill(flipped)
        return ctx.makeImage()
    }

    /// quad で囲まれた領域を台形補正して切り出す。spine があれば左右ページを別々に補正して横に並べる。
    public static func crop(_ image: CGImage, to quad: Quad, spine: Spine?) throws -> CGImage {
        guard let spine else { return try crop(image, to: quad) }
        let size = CGSize(width: image.width, height: image.height)
        let (lq, rq) = quad.clamped(to: size).split(at: spine.clamped(to: size))
        guard lq.isValid, rq.isValid else { return try crop(image, to: quad) }
        let left = try crop(image, to: lq)
        let right = try crop(image, to: rq)
        // 本のページは同じ大きさなので、両ページを同じサイズに揃えて並べる(分割書き出しも中央で割れる)
        let pageW = (left.width + right.width) / 2
        let pageH = (left.height + right.height) / 2
        guard let ctx = CGContext(data: nil, width: pageW * 2, height: pageH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw PageDetectorError.cropFailed }
        ctx.interpolationQuality = .high
        ctx.draw(left, in: CGRect(x: 0, y: 0, width: pageW, height: pageH))
        ctx.draw(right, in: CGRect(x: pageW, y: 0, width: pageW, height: pageH))
        guard let out = ctx.makeImage() else { throw PageDetectorError.cropFailed }
        return out
    }

    /// quad で囲まれた領域を台形補正して切り出す。
    public static func crop(_ image: CGImage, to quad: Quad) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let q = quad.clamped(to: size)
        guard q.isValid else { throw PageDetectorError.cropFailed }

        if q.isAxisAlignedRect {
            let r = q.boundingBox.integral
            if r == CGRect(origin: .zero, size: size) { return image }
            guard let c = image.cropping(to: r) else { throw PageDetectorError.cropFailed }
            return c
        }

        let h = CGFloat(image.height)
        let ci = CIImage(cgImage: image)
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = ci
        f.topLeft = CGPoint(x: q.topLeft.x, y: h - q.topLeft.y)
        f.topRight = CGPoint(x: q.topRight.x, y: h - q.topRight.y)
        f.bottomRight = CGPoint(x: q.bottomRight.x, y: h - q.bottomRight.y)
        f.bottomLeft = CGPoint(x: q.bottomLeft.x, y: h - q.bottomLeft.y)
        guard let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: out.extent) else {
            throw PageDetectorError.cropFailed
        }
        return cg
    }
}
