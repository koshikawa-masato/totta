import Foundation
import CoreGraphics

/// テスト用の合成フレーム生成(動画ファイルは作らない)
enum SyntheticFrames {
    /// 暗い机の上に「見開き」を描いたフレーム。少し回転させて台形補正が効くかも見る。
    static func spreadImage(index: Int, size: CGSize, rotationDegrees: CGFloat = 0, spreadRect: CGRect? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // 机
        ctx.setFillColor(CGColor(red: 0.18, green: 0.15, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        let rect = spreadRect ?? CGRect(x: size.width * 0.15, y: size.height * 0.15, width: size.width * 0.7, height: size.height * 0.7)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: rotationDegrees * .pi / 180)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        // 紙
        ctx.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.9, alpha: 1))
        ctx.fill(rect)
        // のど(中央線)
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: rect.midX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        ctx.strokePath()
        // 本文っぽい線
        ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
        ctx.setLineWidth(2)
        let lines = 12
        for half in 0..<2 {
            let x0 = rect.minX + rect.width * (half == 0 ? 0.06 : 0.56)
            let x1 = x0 + rect.width * 0.38
            for l in 0..<lines {
                let y = rect.minY + rect.height * (0.15 + 0.7 * CGFloat(l) / CGFloat(lines))
                let frac = 0.5 + 0.5 * sin(CGFloat(index * 7 + l * 3 + half))
                ctx.move(to: CGPoint(x: x0, y: y))
                ctx.addLine(to: CGPoint(x: x0 + (x1 - x0) * frac, y: y))
                ctx.strokePath()
            }
        }
        // 図版(ページごとに位置・数が変わる大きめの塗り)
        for k in 0..<(1 + index % 3) {
            let fx = 0.08 + 0.4 * CGFloat((index * 3 + k * 5) % 7) / 7
            let fy = 0.2 + 0.5 * CGFloat((index * 5 + k * 3) % 5) / 5
            ctx.setFillColor(CGColor(gray: 0.35 + 0.1 * CGFloat(k), alpha: 1))
            ctx.fill(CGRect(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy,
                            width: rect.width * 0.18, height: rect.height * 0.15))
        }
        // ページ番号ブロック
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        let block = CGRect(x: rect.minX + rect.width * (0.1 + 0.05 * CGFloat(index % 8)),
                           y: rect.minY + rect.height * 0.05, width: rect.width * 0.1, height: rect.height * 0.06)
        ctx.fill(block)
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    /// ページめくり中のフレーム(手が横切る)
    static func transitionImage(from a: CGImage, to b: CGImage, t: CGFloat, size: CGSize) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(t < 0.5 ? a : b, in: CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1))
        let x = size.width * (1.1 - 1.2 * t)
        ctx.fill(CGRect(x: x, y: size.height * 0.2, width: size.width * 0.25, height: size.height * 0.6))
        return ctx.makeImage()!
    }

    /// カメラから来るフレーム列(時刻付き)を合成する。
    /// pageCount 見開きを hold 秒ずつ静止、間に transition 秒のめくりを入れる。repeatPage の後は
    /// めくらずに手だけ動かして同じページでもう一度静止する(重複として除去されるべき)。
    static func bookSequence(pageCount: Int, hold: Double = 1.5, transition: Double = 0.8, fps: Double = 10,
                             size: CGSize = CGSize(width: 640, height: 360), rotation: CGFloat = 0,
                             repeatPage: Int? = nil) -> [(time: Double, image: CGImage)] {
        var out: [(Double, CGImage)] = []
        var t = 0.0
        let dt = 1.0 / fps
        func emit(_ img: CGImage, seconds: Double) {
            let n = max(1, Int(seconds * fps))
            for _ in 0..<n { out.append((t, img)); t += dt }
        }
        let pages = (0..<pageCount).map { spreadImage(index: $0, size: size, rotationDegrees: rotation) }
        for (i, img) in pages.enumerated() {
            emit(img, seconds: hold)
            if i == repeatPage {
                let steps = 6
                for s in 0..<steps {
                    emit(transitionImage(from: img, to: img, t: CGFloat(s) / CGFloat(steps), size: size), seconds: transition / Double(steps))
                }
                emit(img, seconds: hold)
            }
            if i + 1 < pages.count {
                let steps = 8
                for s in 0..<steps {
                    emit(transitionImage(from: img, to: pages[i + 1], t: CGFloat(s) / CGFloat(steps), size: size), seconds: transition / Double(steps))
                }
            }
        }
        return out.map { (time: $0.0, image: $0.1) }
    }
}
