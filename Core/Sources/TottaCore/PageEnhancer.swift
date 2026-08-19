import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// 切り出し後のページ画像に対する補正のパラメータ
public struct EnhanceSettings: Equatable, Sendable {
    /// 照明ムラ・影を取り除いて紙面を均一な白にする
    public var flattenLighting: Bool = true
    /// レベル補正の黒点(0-1)。これ以下は黒
    public var blackPoint: Double = 0.25
    /// レベル補正の白点(0-1)。これ以上は白
    public var whitePoint: Double = 0.92
    /// 指・手の映り込みを紙色で塗りつぶす。
    /// 誤検出するとページを消してしまうため既定はオフ。
    public var removeFingers: Bool = false
    /// 指と判定した領域がページのこの割合を超えたら、誤検出とみなして何もしない
    public var maxFingerCoverage: Double = 0.10
    /// グレースケールで出力(本文スキャンに色は不要で、ファイルが小さくなる)
    public var grayscale: Bool = true

    public init() {}

    public var isIdentity: Bool { !flattenLighting && !removeFingers && !grayscale }
}

public struct EnhanceResult: Sendable {
    public let image: CGImage
    /// 指として塗りつぶした面積の割合(0-1)
    public let fingerCoverage: Double
    /// 手が検出されたか
    public let handsDetected: Bool
}

/// ページ画像の補正:紙面均一化(照明ムラ除去+レベル補正)と、指の映り込みの除去。
/// すべてオンデバイス(CoreImage + Vision)で処理し、外部には何も送らない。
public enum PageEnhancer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// CoreImage が内部に持つテクスチャキャッシュを解放する。長いバッチ処理の途中で呼ぶ。
    public static func clearCaches() {
        ciContext.clearCaches()
    }
    /// 背景推定・マスク計算を行う縮小幅
    private static let workWidth: CGFloat = 1024

    public static func enhance(_ image: CGImage, settings: EnhanceSettings) throws -> EnhanceResult {
        if settings.isIdentity {
            return EnhanceResult(image: image, fingerCoverage: 0, handsDetected: false)
        }
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let scale = min(1, workWidth / extent.width)

        // 1. 紙面(背景)の推定: 縮小 → 輝度 → 最大値フィルタで文字を消す → ぼかし → 拡大
        let background = estimateBackground(source, scale: scale)

        var working = source
        var coverage = 0.0
        var hands = false

        // 2. 指の除去: マスクを作り、背景推定画像で埋める
        if settings.removeFingers {
            if let mask = fingerMask(image: image, background: background, scale: scale,
                                     maxCoverage: settings.maxFingerCoverage) {
                coverage = mask.coverage
                hands = mask.handsDetected
                if coverage > 0 {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = background            // マスク白の部分はこちら
                    blend.backgroundImage = working          // マスク黒の部分はこちら
                    blend.maskImage = mask.image
                    working = blend.outputImage ?? working
                }
            }
        }

        // 3. 照明ムラ除去: 元画像 / 背景(リニア空間)→ レベル補正
        if settings.flattenLighting {
            let divide = CIFilter.divideBlendMode()
            divide.inputImage = background                 // divide = background / input なので逆に渡す
            divide.backgroundImage = working
            if let divided = divide.outputImage {
                working = levels(divided.cropped(to: extent), black: settings.blackPoint, white: settings.whitePoint)
            }
        }

        working = working.cropped(to: extent)
        guard var out = ciContext.createCGImage(working, from: extent) else {
            throw PageDetectorError.cropFailed
        }
        if settings.grayscale, let mono = Self.grayscale(out) {
            out = mono
        }
        return EnhanceResult(image: out, fingerCoverage: coverage, handsDetected: hands)
    }

    /// 本物の 1 チャンネル(DeviceGray)画像に変換する。
    /// CIFilter の photoEffectMono は見た目がグレーになるだけで RGB のままなので、
    /// ファイルサイズを落とすにはここで色空間ごと変換する必要がある。
    static func grayscale(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - 背景推定

    private static func luminance(_ image: CIImage) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let w = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        m.rVector = w; m.gVector = w; m.bVector = w
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    static func estimateBackground(_ source: CIImage, scale: CGFloat) -> CIImage {
        let extent = source.extent
        var img = luminance(source)
        if scale < 1 {
            img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let small = img.extent
        // 文字(暗い)を消す: 最大値フィルタ。縮小後の文字ストローク幅を十分超える半径
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = img.clampedToExtent()
        dilate.radius = 8
        img = dilate.outputImage?.cropped(to: small) ?? img
        // 中央値寄りにするため最小値で少し戻す(太い罫線などの影響を抑える)
        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = img.clampedToExtent()
        erode.radius = 3
        img = erode.outputImage?.cropped(to: small) ?? img
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = img.clampedToExtent()
        blur.radius = 24
        img = blur.outputImage?.cropped(to: small) ?? img
        if scale < 1 {
            img = img.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
        // 端の丸め誤差で足りない分を埋める
        return img.clampedToExtent().cropped(to: extent)
    }

    private static func levels(_ image: CIImage, black: Double, white: Double) -> CIImage {
        let b = CGFloat(min(black, white - 0.01)), w = CGFloat(max(white, black + 0.01))
        let s = 1 / (w - b)
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: -b * s, y: -b * s, z: -b * s, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        return clamp.outputImage ?? image
    }

    // MARK: - 指マスク

    struct FingerMask {
        let image: CIImage
        let coverage: Double
        let handsDetected: Bool
    }

    /// 指の検出。
    ///
    /// 本文用紙(クリーム色)は肌色に近いので、肌色だけを条件にすると紙そのものを「指」と判定して
    /// ページを消してしまう。そこで次をすべて満たすものだけを指とみなす。
    ///   1. 紙より明らかに彩度が高い(紙の色を画像から推定して基準にする)
    ///   2. 紙より暗い(照らされた紙面より指は暗く写る)
    ///   3. 肌色の色相
    ///   4. Vision で手が検出され、その関節位置を含む連結領域である
    ///      (紙の影と指は色だけでは分けきれないため、手が写っていると確認できたときだけ消す)
    ///   5. 領域が細長い(縦横どちらかがページの半分未満)= 端から入り込んだ形
    ///   6. 全体の被覆率が上限以下。超えたら誤検出とみなして何も消さない
    ///
    /// - Parameter seedsOverride: テスト用。手のポーズ検出の代わりに使う座標(縮小画像の画素座標)
    static func fingerMask(image: CGImage, background: CIImage, scale: CGFloat, maxCoverage: Double,
                           seedsOverride: [(Int, Int)]? = nil) -> FingerMask? {
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data.map({ $0.assumingMemoryBound(to: UInt8.self) }) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = ctx.bytesPerRow

        struct HSV { var h: Float; var s: Float; var v: Float }
        func hsv(_ x: Int, _ y: Int) -> HSV {
            let p = data + y * bpr + x * 4
            let r = Float(p[0]) / 255, g = Float(p[1]) / 255, b = Float(p[2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            var hue: Float = 0
            if d > 0 {
                if mx == r { hue = (g - b) / d } else if mx == g { hue = 2 + (b - r) / d } else { hue = 4 + (r - g) / d }
                hue *= 60
                if hue < 0 { hue += 360 }
            }
            return HSV(h: hue, s: mx > 0 ? d / mx : 0, v: mx)
        }

        // 紙の基準色: 明るい側 40% の画素の中央値(彩度・明度)
        var vs: [Float] = []
        vs.reserveCapacity(w * h)
        for y in 0..<h { for x in 0..<w { vs.append(hsv(x, y).v) } }
        let sortedV = vs.sorted()
        let brightThreshold = sortedV[Int(Double(sortedV.count) * 0.6)]
        var paperSats: [Float] = [], paperVals: [Float] = []
        for y in 0..<h {
            for x in 0..<w {
                let c = hsv(x, y)
                if c.v >= brightThreshold { paperSats.append(c.s); paperVals.append(c.v) }
            }
        }
        guard !paperSats.isEmpty else { return nil }
        let paperSat = paperSats.sorted()[paperSats.count / 2]
        let paperVal = paperVals.sorted()[paperVals.count / 2]

        // 手のポーズ。これが取れなければ何も消さない
        var seeds: [(Int, Int)] = seedsOverride ?? []
        if seedsOverride == nil {
            let handReq = VNDetectHumanHandPoseRequest()
            handReq.maximumHandCount = 4
            if let small = ctx.makeImage(), (try? VNImageRequestHandler(cgImage: small, options: [:]).perform([handReq])) != nil {
                for obs in handReq.results ?? [] {
                    if let pts = try? obs.recognizedPoints(.all) {
                        for (_, p) in pts where p.confidence > 0.3 {
                            seeds.append((Int(p.location.x * CGFloat(w - 1)), Int((1 - p.location.y) * CGFloat(h - 1))))
                        }
                    }
                }
            }
        }
        let handsDetected = !seeds.isEmpty
        // 手が写っていないなら、肌色に見えるものは紙の影などの可能性が高いので何もしない
        guard handsDetected else {
            return FingerMask(image: CIImage.empty(), coverage: 0, handsDetected: false)
        }

        // 指の候補: 肌色 かつ 紙より彩度が高く 紙より暗い
        let minSat = max(0.22, paperSat + 0.10)
        let maxVal = paperVal * 1.02   // 反射で白飛びした部分だけ除く
        var cand = [Bool](repeating: false, count: w * h)
        var candCount = 0
        for y in 0..<h {
            for x in 0..<w {
                let c = hsv(x, y)
                guard c.s >= minSat, c.v <= maxVal, c.v > 0.12 else { continue }
                if c.h <= 45 || c.h >= 345 {
                    cand[y * w + x] = true
                    candCount += 1
                }
            }
        }
        let empty = FingerMask(image: CIImage.empty(), coverage: 0, handsDetected: handsDetected)
        if candCount == 0 { return empty }

        var seedSet = Set<Int>()
        for (sx, sy) in seeds where sx >= 0 && sy >= 0 && sx < w && sy < h {
            for dy in -3...3 { for dx in -3...3 {
                let x = sx + dx, y = sy + dy
                if x >= 0, y >= 0, x < w, y < h { seedSet.insert(y * w + x) }
            } }
        }

        // 連結成分ラベリング(4近傍)
        var label = [Int32](repeating: -1, count: w * h)
        var keep = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var component: Int32 = 0
        let minArea = max(40, (w * h) / 1500)
        for start in 0..<(w * h) where cand[start] && label[start] < 0 {
            var members: [Int] = []
            var hasSeed = false
            var minX = w, maxX = 0, minY = h, maxY = 0
            stack.append(start)
            label[start] = component
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                if !hasSeed, seedSet.contains(i) { hasSeed = true }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, cand[i - 1], label[i - 1] < 0 { label[i - 1] = component; stack.append(i - 1) }
                if x < w - 1, cand[i + 1], label[i + 1] < 0 { label[i + 1] = component; stack.append(i + 1) }
                if y > 0, cand[i - w], label[i - w] < 0 { label[i - w] = component; stack.append(i - w) }
                if y < h - 1, cand[i + w], label[i + w] < 0 { label[i + w] = component; stack.append(i + w) }
            }
            component += 1
            guard members.count >= minArea, hasSeed else { continue }
            // 端から入り込んだ細長い形か(縦横どちらかがページの半分未満)
            let bw = Double(maxX - minX + 1) / Double(w)
            let bh = Double(maxY - minY + 1) / Double(h)
            guard min(bw, bh) < 0.5 else { continue }
            // 1 つの成分が大きすぎるものは紙の誤検出
            guard Double(members.count) / Double(w * h) <= maxCoverage else { continue }
            for i in members { keep[i] = true }
        }
        let kept = keep.reduce(0) { $0 + ($1 ? 1 : 0) }
        let coverage = Double(kept) / Double(w * h)
        if kept == 0 { return empty }
        // 合計が上限を超えるなら、指ではなく紙を拾っている可能性が高いので何もしない
        if coverage > maxCoverage { return empty }

        var maskBytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where keep[i] { maskBytes[i] = 255 }
        guard let maskCG = maskBytes.withUnsafeMutableBytes({ buf -> CGImage? in
            guard let mctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return mctx.makeImage()
        }) else { return nil }
        var mask = CIImage(cgImage: maskCG)
        let smallExtent = mask.extent
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = mask.clampedToExtent()
        grow.radius = 4
        mask = grow.outputImage?.cropped(to: smallExtent) ?? mask
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = mask.clampedToExtent()
        soften.radius = 2
        mask = soften.outputImage?.cropped(to: smallExtent) ?? mask
        if scale < 1 {
            mask = mask.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
        mask = mask.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return FingerMask(image: mask, coverage: coverage, handsDetected: handsDetected)
    }
}
