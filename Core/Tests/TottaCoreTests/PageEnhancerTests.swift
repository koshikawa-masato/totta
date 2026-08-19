import XCTest
@testable import TottaCore

final class PageEnhancerTests: XCTestCase {
    /// 影のグラデーション + 本文線 + 縁から入る「指」 + 縁から離れた肌色の挿絵、を持つ見開き画像
    static func makePage(size: CGSize = CGSize(width: 1200, height: 800), withFinger: Bool = true) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // 紙: 左が暗く右が明るいグラデーション(照明ムラ)
        let colors = [CGColor(red: 0.55, green: 0.53, blue: 0.5, alpha: 1), CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: 0), options: [])
        // 本文の線
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setLineWidth(3)
        for l in 0..<20 {
            let y = 80 + CGFloat(l) * 32
            ctx.move(to: CGPoint(x: 80, y: y)); ctx.addLine(to: CGPoint(x: 540, y: y)); ctx.strokePath()
            ctx.move(to: CGPoint(x: 660, y: y)); ctx.addLine(to: CGPoint(x: 1120, y: y)); ctx.strokePath()
        }
        // 縁から離れた肌色の挿絵(消してはいけない)
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 700, y: 300, width: 160, height: 120))
        if withFinger {
            // 下縁から入ってくる指(肌色)
            ctx.setFillColor(CGColor(red: 0.85, green: 0.6, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 300, y: 0, width: 90, height: 260))
            ctx.fillEllipse(in: CGRect(x: 300, y: 215, width: 90, height: 90))
        }
        return ctx.makeImage()!
    }

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
    }
    private func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }

    func testFlattenMakesPaperUniformAndKeepsText() throws {
        let img = Self.makePage(withFinger: false)
        var s = EnhanceSettings()
        s.removeFingers = false
        let out = try PageEnhancer.enhance(img, settings: s).image
        XCTAssertEqual(out.width, img.width)
        // 元画像では左右の紙の明るさが大きく違う
        let beforeLeft = luma(pixel(img, 30, 400)), beforeRight = luma(pixel(img, 1170, 400))
        XCTAssertGreaterThan(beforeRight - beforeLeft, 0.3)
        // 補正後は左右とも白に近く、差が小さい
        let afterLeft = luma(pixel(out, 30, 400)), afterRight = luma(pixel(out, 1170, 400))
        XCTAssertGreaterThan(afterLeft, 0.9, "left=\(afterLeft)")
        XCTAssertGreaterThan(afterRight, 0.9, "right=\(afterRight)")
        XCTAssertLessThan(abs(afterLeft - afterRight), 0.08)
        // 本文の線は黒いまま (y=80 の線上, 画像座標は上下反転しているので h-80)
        let textY = img.height - 80
        XCTAssertLessThan(luma(pixel(out, 200, textY)), 0.3)
    }

    /// 手が検出されない限り何も消さない(色だけで紙の影を指と誤認しないため)
    func testNothingRemovedWithoutHandDetection() throws {
        let img = Self.makePage(withFinger: true)
        var s = EnhanceSettings(); s.removeFingers = true
        let result = try PageEnhancer.enhance(img, settings: s)
        XCTAssertFalse(result.handsDetected)
        XCTAssertEqual(result.fingerCoverage, 0, accuracy: 0.0001)
    }

    /// 手が検出された場合は、その位置の肌色領域だけを紙色で埋め、挿絵は残す
    func testFingerRemovedWhenHandDetected() throws {
        let img = Self.makePage(withFinger: true)
        let scale = min(1, 1024 / CGFloat(img.width))
        let bg = PageEnhancer.estimateBackground(CIImage(cgImage: img), scale: scale)
        // 指の中心(元画像 x=345, 上から 1200-260+45 付近)を手の関節位置として与える
        let seed = (Int(345 * scale), Int((CGFloat(img.height) - 130) * scale))
        let mask = try XCTUnwrap(PageEnhancer.fingerMask(image: img, background: bg, scale: scale,
                                                         maxCoverage: 0.10, seedsOverride: [seed]))
        XCTAssertGreaterThan(mask.coverage, 0.01, "指が検出されていない")
        XCTAssertLessThan(mask.coverage, 0.08, "消しすぎ")
    }

    /// 実際の本のクリーム色の紙は肌色に近い。紙そのものを「指」と判定してページを消してはいけない。
    static func creamPage(size: CGSize = CGSize(width: 1400, height: 900)) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // クリーム色の紙 + 端に向かって暗くなる影(縁に接する暗いクリーム領域ができる)
        let colors = [CGColor(red: 0.95, green: 0.91, blue: 0.80, alpha: 1),
                      CGColor(red: 0.62, green: 0.57, blue: 0.45, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: size.width * 0.35, y: 0), end: CGPoint(x: 0, y: 0), options: [.drawsAfterEndLocation])
        ctx.setStrokeColor(CGColor(gray: 0.12, alpha: 1)); ctx.setLineWidth(3)
        for l in 0..<22 {
            let y = 60 + CGFloat(l) * 36
            ctx.move(to: CGPoint(x: 120, y: y)); ctx.addLine(to: CGPoint(x: 1280, y: y)); ctx.strokePath()
        }
        return ctx.makeImage()!
    }

    func testCreamPaperIsNotMistakenForFinger() throws {
        let img = Self.creamPage()
        var s = EnhanceSettings(); s.removeFingers = true
        let result = try PageEnhancer.enhance(img, settings: s)
        XCTAssertEqual(result.fingerCoverage, 0, accuracy: 0.001, "紙そのものを指と誤検出している")
        // 本文の線は残っている(消されていない)
        var dark = 0
        let out = result.image
        let ctx = CGContext(data: nil, width: out.width, height: out.height, bitsPerComponent: 8,
                            bytesPerRow: out.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(out, in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: out.width * out.height * 4, by: 4) where p[i] < 100 { dark += 1 }
        XCTAssertGreaterThan(dark, out.width * out.height / 200, "本文が消えている")
    }

    /// 誤検出で広い面積を塗ろうとしたら、何もしない方に倒す
    func testHugeMaskIsRejected() throws {
        let img = Self.creamPage()
        var s = EnhanceSettings(); s.removeFingers = true; s.maxFingerCoverage = 0.0001
        let result = try PageEnhancer.enhance(img, settings: s)
        XCTAssertEqual(result.fingerCoverage, 0, accuracy: 0.0001)
    }

    func testIdentityWhenDisabled() throws {
        let img = Self.makePage()
        var s = EnhanceSettings()
        s.flattenLighting = false; s.removeFingers = false; s.grayscale = false
        let out = try PageEnhancer.enhance(img, settings: s)
        XCTAssertTrue(out.image === img)
    }
}

final class GrayscaleTests: XCTestCase {
    func testGrayscaleOutputIsSingleChannel() throws {
        let img = PageEnhancerTests.creamPage()
        XCTAssertEqual(img.colorSpace?.numberOfComponents, 3)
        var s = EnhanceSettings()
        XCTAssertTrue(s.grayscale, "グレースケールが既定になっていない")
        s.removeFingers = false
        let out = try PageEnhancer.enhance(img, settings: s).image
        XCTAssertEqual(out.colorSpace?.numberOfComponents, 1, "1 チャンネルになっていない(見た目だけグレー)")
        XCTAssertEqual(out.bitsPerPixel, 8)
    }

    func testColorOutputWhenDisabled() throws {
        let img = PageEnhancerTests.creamPage()
        var s = EnhanceSettings()
        s.grayscale = false
        s.removeFingers = false
        let out = try PageEnhancer.enhance(img, settings: s).image
        XCTAssertEqual(out.colorSpace?.numberOfComponents, 3)
    }

    /// グレースケールの方が JPEG が小さくなること
    func testGrayscaleIsSmaller() throws {
        let img = PageEnhancerTests.creamPage(size: CGSize(width: 2000, height: 1400))
        var gray = EnhanceSettings(); gray.removeFingers = false
        var color = EnhanceSettings(); color.removeFingers = false; color.grayscale = false
        let g = try PageEnhancer.enhance(img, settings: gray).image
        let c = try PageEnhancer.enhance(img, settings: color).image
        let gs = ImageUtils.jpegData(g, quality: 0.75)!.count
        let cs = ImageUtils.jpegData(c, quality: 0.75)!.count
        XCTAssertLessThan(gs, cs, "グレースケールの方が大きい (gray=\(gs) color=\(cs))")
    }
}
