import XCTest
@testable import TottaCore

/// 4K 相当のページを流したときのピークメモリと所要時間を測る。
/// 既定ではスキップ。`TOTTA_MEM=<ページ数> [TOTTA_OCR=1] swift test --filter ExportBenchmarkTests` で実行する。
final class ExportBenchmarkTests: XCTestCase {
    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    func testPeakMemoryAndSpeed() throws {
        guard ProcessInfo.processInfo.environment["TOTTA_MEM"] != nil else { throw XCTSkip("") }
        let size = CGSize(width: 4032, height: 3024)
        let count = Int(ProcessInfo.processInfo.environment["TOTTA_MEM"] ?? "12") ?? 12
        let quad = Quad(rect: CGRect(x: 600, y: 450, width: 2800, height: 2100))
        var jobs: [ExportJob] = []
        var jpegBytes = 0
        for i in 0..<count {
            autoreleasepool {
                let img = SyntheticFrames.spreadImage(index: i, size: size)   // ページごとに違う絵
                let jpeg = ImageUtils.jpegData(img, quality: 0.9)!
                jpegBytes += jpeg.count
                jobs.append(ExportJob(frameJPEG: jpeg, page: CapturedPage(time: Double(i), frameSize: size, quad: quad,
                                                                          spine: Spine.centered(in: quad), source: .auto)))
            }
        }
        print("JPEG 合計: \(jpegBytes / 1024) KB, 1 ページ展開時 \(Int(size.width * size.height * 4 / 1_048_576)) MB")
        var en = EnhanceSettings(); en.removeFingers = false
        var ocr = OCRSettings(); ocr.enabled = ProcessInfo.processInfo.environment["TOTTA_OCR"] != nil
        var ex = ExportSettings(); ex.splitSpread = true

        let start = residentMB()
        var peak = start
        let stop = DispatchQueue(label: "mem")
        var running = true
        stop.async { while running { peak = max(peak, self.residentMB()); usleep(20_000) } }
        let t0 = Date()
        let data = try PDFPipeline.build(jobs: jobs, enhance: en, ocr: ocr, export: ex).pdf
        running = false
        usleep(50_000)
        print(String(format: "PAGES=%d 時間=%.1fs PDF=%.1fMB  RSS start=%.0fMB peak=%.0fMB 増加=%.0fMB",
                     count, Date().timeIntervalSince(t0), Double(data.count) / 1_048_576, start, peak, peak - start))
    }
}
