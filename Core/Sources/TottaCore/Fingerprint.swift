import Foundation
import CoreGraphics
import CoreVideo

/// 動き検出・重複判定用の縮小グレースケール画像
public struct Fingerprint: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 0...255 の輝度
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// 平均絶対差 (0-255)
    public func distance(to other: Fingerprint) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        for i in 0..<values.count {
            sum += abs(values[i] - other.values[i])
        }
        return sum / Float(values.count)
    }

    /// CGImage を固定サイズのグレースケールに縮小して作る
    public static func make(from image: CGImage, width fw: Int, height fh: Int) -> Fingerprint {
        var bytes = [UInt8](repeating: 0, count: fw * fh)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: fw, height: fh))
            return true
        }
        guard ok else { return Fingerprint(width: fw, height: fh, values: [Float](repeating: 0, count: fw * fh)) }
        return Fingerprint(width: fw, height: fh, values: bytes.map { Float($0) })
    }

    /// CGImage から動き検出用の指紋(幅 fw、縦横比維持)
    public static func motionFingerprint(_ image: CGImage, width fw: Int) -> Fingerprint {
        let fh = max(1, Int((Double(fw) * Double(image.height) / Double(max(image.width, 1))).rounded()))
        return make(from: image, width: fw, height: fh)
    }

    /// ページ画像同士の比較に使う標準サイズ
    public static let pageCompareSize = (width: 128, height: 80)

    public static func pageFingerprint(_ image: CGImage) -> Fingerprint {
        make(from: image, width: pageCompareSize.width, height: pageCompareSize.height)
    }

    /// BGRA の CVPixelBuffer からセル平均で作る(カメラフレームの動き検出用)
    public static func make(from pixelBuffer: CVPixelBuffer, width fw: Int) -> Fingerprint {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let fh = max(1, Int((Double(fw) * Double(h) / Double(max(w, 1))).rounded()))
        var values = [Float](repeating: 0, count: fw * fh)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return Fingerprint(width: fw, height: fh, values: values)
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let cellW = Double(w) / Double(fw)
        let cellH = Double(h) / Double(fh)
        let sub = 4
        for gy in 0..<fh {
            for gx in 0..<fw {
                var acc: Float = 0
                for sy in 0..<sub {
                    let y = min(h - 1, Int((Double(gy) + (Double(sy) + 0.5) / Double(sub)) * cellH))
                    let row = ptr + y * bpr
                    for sx in 0..<sub {
                        let x = min(w - 1, Int((Double(gx) + (Double(sx) + 0.5) / Double(sub)) * cellW))
                        let p = row + x * 4
                        acc += 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
                    }
                }
                values[gy * fw + gx] = acc / Float(sub * sub)
            }
        }
        return Fingerprint(width: fw, height: fh, values: values)
    }
}
