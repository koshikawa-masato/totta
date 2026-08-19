import SwiftUI
import Observation
import TottaCore
import UniformTypeIdentifiers
import CoreGraphics

/// アプリ全体の状態。
///
/// データ保持ポリシー:
/// - 入力はライブカメラのみ。動画ファイルの読み込みは行わない。
/// - カメラ映像は録画も一時保存もしない。取り込んだページのフレームはメモリ上(JPEG エンコード済み Data)にのみ持つ。
/// - ディスクに書くのは書き出した最終 PDF だけ。
/// - PDF の書き出しが完了したら、ページ・フレーム・サムネイルなど途中データはすべて破棄する。
@MainActor
@Observable
final class ProjectModel {
    enum Phase: Equatable {
        case empty
        case ready
        case exporting(Double, String)
    }

    // MARK: 状態
    var phase: Phase = .empty
    var pages: [CapturedPage] = []
    var selectedPageID: UUID?
    var analysisSettings = AnalysisSettings() {
        didSet { liveScanner?.settings = analysisSettings }
    }
    var exportSettings = ExportSettings()
    var enhanceSettings = EnhanceSettings()
    var ocrSettings = OCRSettings()
    var errorMessage: String?
    var infoMessage: String?
    var thumbnails: [UUID: CGImage] = [:]
    var showSettings = false

    // ライブカメラ
    private(set) var isLive = false
    private(set) var liveScanner: LiveScanner?
    var liveState = LiveState()
    var liveFlash = false
    /// タップでピント固定した位置(プレビュー座標)。レティクル表示用
    var focusReticle: CGPoint?
    /// キャリブレーション中の状態(静止画 1 枚の上で枠とのど線を合わせる)
    struct Calibration {
        var image: CGImage
        /// image のピクセルサイズ(quad/spine の座標系)
        var frameSize: CGSize
        var quad: Quad
        var spine: Spine?
        /// 自動検出で初期値が入ったか
        var detected: Bool
    }
    var calibration: Calibration?
    var isPreparingCalibration = false
    /// キャリブレーションせずに(毎回自動検出で)取り込むことを選んだ
    var skipCalibration = false
    /// 端末が縦向きでも、映像を横向き(見開き向き)のまま扱う
    var lockLandscape: Bool = ProjectModel.loadLockLandscape() {
        didSet { UserDefaults.standard.set(lockLandscape, forKey: Self.lockLandscapeKey) }
    }
    private static let lockLandscapeKey = "totta.lockLandscape"
    private static func loadLockLandscape() -> Bool {
        UserDefaults.standard.object(forKey: lockLandscapeKey) as? Bool ?? true
    }

    /// 基準枠。設定中は以降の取り込みに検出なしで適用される(座標のみ UserDefaults に保存)
    private(set) var frameTemplate: FrameTemplate? {
        didSet {
            liveScanner?.template = frameTemplate
            Self.persistTemplate(frameTemplate)
        }
    }
    private static let templateKey = "totta.frameTemplate"
    var availableCameras: [(id: String, name: String)] = []
    var selectedCameraID: String?
    /// 取り込んだフレーム(メモリ内 JPEG)。ディスクには書かない。
    private var liveFrames: [UUID: Data] = [:]

    // 書き出し
    var exportedDocument: PDFFile?
    /// OCR 結果から作った Markdown(OCR オフなら nil)。保存時に実際の PDF 名で作り直す
    var exportedMarkdown: MarkdownFile?
    /// Markdown を作り直すための元データ(ページごとの OCR テキストとタイトル)
    private var exportedPageTexts: [String] = []
    private var exportedTitle: String?
    /// 保存ダイアログ(PDF と .md で 1 つを使い回す)
    var isShowingExporter = false
    private(set) var pendingFile: ExportableFile?
    private(set) var pendingFileType: UTType = .pdf
    private(set) var pendingFileName = "totta.pdf"
    private enum PendingKind { case pdf, markdown }
    private var pendingKind: PendingKind = .pdf
    /// 「破棄」で閉じた場合、シートが閉じたあとにすべて捨てて最初の画面に戻る
    private var pendingFullDiscard = false
    /// 書き出し開始時刻(残り時間の見積もり用)
    private(set) var exportStartedAt: Date?
    var isShowingPDFPreview = false
    /// 保存したファイル名(シート内の表示用)
    var savedPDFName: String?
    var savedMarkdownName: String?
    var suggestedPDFName = "totta.pdf"
    var suggestedMarkdownName: String {
        (suggestedPDFName as NSString).deletingPathExtension + ".md"
    }
    private var exportTask: Task<Void, Never>?

    private var warnedTemplateMismatch = false
    private let frameCache = NSCache<NSString, CGImage>()
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        frameCache.totalCostLimit = 1_200_000_000
        frameCache.countLimit = 40
        frameTemplate = Self.loadTemplate()
    }

    private static func persistTemplate(_ t: FrameTemplate?) {
        if let t, let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: templateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: templateKey)
        }
    }
    private static func loadTemplate() -> FrameTemplate? {
        guard let data = UserDefaults.standard.data(forKey: templateKey) else { return nil }
        return try? JSONDecoder().decode(FrameTemplate.self, from: data)
    }

    // MARK: 派生値
    var isBusy: Bool {
        if case .exporting = phase { return true }
        return false
    }
    var includedPages: [CapturedPage] { pages.filter(\.isIncluded) }
    var selectedPage: CapturedPage? { pages.first { $0.id == selectedPageID } }
    func page(_ id: UUID) -> CapturedPage? { pages.first { $0.id == id } }
    func index(of id: UUID) -> Int? { pages.firstIndex { $0.id == id } }
    /// 出力上のページ番号(除外ページは数えない)
    func outputNumber(of id: UUID) -> Int? {
        var n = 0
        for p in pages {
            if p.isIncluded { n += 1 }
            if p.id == id { return p.isIncluded ? n : nil }
        }
        return nil
    }
    func isSimilarToPrevious(_ page: CapturedPage) -> Bool {
        (page.differenceFromPrevious ?? .greatestFiniteMagnitude) < analysisSettings.similarWarningThreshold
    }

    // MARK: ライブカメラ
    func refreshCameras() {
        availableCameras = LiveScanner.availableCameras().map { ($0.uniqueID, $0.localizedName) }
        if selectedCameraID == nil || !availableCameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = availableCameras.first?.id
        }
    }

    func startLive() {
        guard !isLive else { return }
        Task {
            guard await LiveScanner.requestAccess() else {
                errorMessage = LiveScannerError.accessDenied.localizedDescription
                return
            }
            refreshCameras()
            let scanner = LiveScanner(settings: analysisSettings)
            do {
                try scanner.configure(deviceID: selectedCameraID)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            scanner.onState = { [weak self] state in
                Task { @MainActor [weak self] in self?.liveState = state }
            }
            scanner.onCapture = { [weak self] capture in
                Task { @MainActor [weak self] in self?.handleLiveCapture(capture) }
            }
            scanner.template = frameTemplate
            calibration = nil
            isPreparingCalibration = false
            skipCalibration = false
            warnedTemplateMismatch = false
            liveScanner = scanner
            isLive = true
            phase = .ready
            if pages.isEmpty {
                suggestedPDFName = "scan-\(Self.dateStamp()).pdf"
                exportSettings.title = "totta scan"
            }
            selectedPageID = nil
            scanner.start()
        }
    }

    func switchCamera(to id: String) {
        selectedCameraID = id
        guard isLive, let scanner = liveScanner else { return }
        do {
            try scanner.configure(deviceID: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// カメラを止める。clearPages が false なら取り込んだページは残す(あとから PDF にできる)。
    func stopLive(clearPages: Bool) {
        liveScanner?.stop()
        liveScanner?.onCapture = nil
        liveScanner?.onState = nil
        liveScanner = nil
        isLive = false
        liveState = LiveState()
        focusReticle = nil
        calibration = nil
        isPreparingCalibration = false
        if clearPages { discardPages() }
        if pages.isEmpty { phase = .empty }
    }

    func liveCaptureNow() {
        liveScanner?.captureNow()
    }

    /// 自動取り込みの開始/停止(大きなボタン)
    func toggleCapturing() {
        guard let scanner = liveScanner else { return }
        scanner.setArmed(!liveState.isArmed)
    }

    /// プレビューをタップ: その点でピント・露出・WB を合わせて固定
    func lockFocus(devicePoint: CGPoint, layerPoint: CGPoint) {
        guard let scanner = liveScanner else { return }
        do {
            try scanner.lockFocusAndExposure(atDevicePoint: devicePoint)
            focusReticle = layerPoint
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if focusReticle == layerPoint { focusReticle = nil } }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// ● で取り込みを開始できるか(キャリブレーション済み、または自動検出を選んだ)
    var canStartCapture: Bool { frameTemplate != nil || skipCalibration }

    /// 基準枠が現在のカメラフレームと同じ向き・縦横比か(違えば適用されない)
    var templateMatchesCurrentFrame: Bool {
        guard let t = frameTemplate else { return false }
        let size = liveState.frameSize
        guard size.width > 0, size.height > 0 else { return true }
        return t.matchesAspect(of: size)
    }

    /// 現在のプレビューから 1 枚取り出してキャリブレーションを始める
    func beginCalibration() {
        guard let scanner = liveScanner, !isPreparingCalibration else { return }
        scanner.setArmed(false)
        isPreparingCalibration = true
        let minimumSize = analysisSettings.minimumPageSize
        let existing = frameTemplate
        scanner.grabFrame { [weak self] frame in
            Task.detached(priority: .userInitiated) { [weak self] in
                let display = ImageUtils.resized(frame, maxDimension: 1600)
                let fullSize = CGSize(width: frame.width, height: frame.height)
                let displaySize = CGSize(width: display.width, height: display.height)
                var quad = Quad.fullFrame(displaySize)
                var spine: Spine? = nil
                var detected = false
                if let t = existing {
                    quad = t.quad(for: displaySize)
                    spine = t.spine(for: displaySize)
                } else if let d = (try? PageDetector.detect(in: frame, minimumSize: minimumSize)) ?? nil {
                    quad = d.quad.scaled(from: fullSize, to: displaySize)
                    spine = d.spine?.scaled(from: fullSize, to: displaySize)
                    detected = true
                }
                await MainActor.run { [quad, spine, detected] in
                    guard let self else { return }
                    self.calibration = Calibration(image: display, frameSize: displaySize,
                                                   quad: quad.clamped(to: displaySize),
                                                   spine: spine?.clamped(to: displaySize), detected: detected)
                    self.isPreparingCalibration = false
                }
            }
        }
    }

    func updateCalibrationQuad(_ quad: Quad) {
        guard var c = calibration else { return }
        c.quad = quad.clamped(to: c.frameSize)
        calibration = c
    }

    func updateCalibrationSpine(_ spine: Spine?) {
        guard var c = calibration else { return }
        c.spine = spine?.clamped(to: c.frameSize)
        calibration = c
    }

    func toggleCalibrationSpine() {
        guard let c = calibration else { return }
        updateCalibrationSpine(c.spine == nil ? Spine.centered(in: c.quad) : nil)
    }

    func setCalibrationFullFrame() {
        guard var c = calibration else { return }
        c.quad = Quad.fullFrame(c.frameSize)
        c.spine = nil
        calibration = c
    }

    func redetectCalibration() {
        guard let c = calibration else { return }
        let image = c.image, size = c.frameSize, minimumSize = analysisSettings.minimumPageSize
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                (try? PageDetector.detect(in: image, minimumSize: minimumSize)) ?? nil
            }.value
            guard var cur = calibration else { return }
            if let d = result {
                cur.quad = d.quad.clamped(to: size)
                cur.spine = d.spine?.clamped(to: size)
                cur.detected = true
                calibration = cur
            } else {
                infoMessage = "ページの枠を検出できませんでした。四隅を手で合わせてください。"
            }
        }
    }

    /// キャリブレーション確定 → 基準枠として保存
    func confirmCalibration() {
        guard let c = calibration else { return }
        frameTemplate = FrameTemplate(quad: c.quad, spine: c.spine, frameSize: c.frameSize)
        skipCalibration = false
        warnedTemplateMismatch = false
        calibration = nil
    }

    func cancelCalibration() {
        calibration = nil
    }

    /// キャリブレーションせずに自動検出で取り込む
    func startWithoutCalibration() {
        skipCalibration = true
        calibration = nil
        liveScanner?.setArmed(true)
    }

    func setZoom(_ z: CGFloat) {
        liveScanner?.setZoom(z)
    }

    func unlockFocus() {
        try? liveScanner?.unlockFocusAndExposure()
        focusReticle = nil
    }

    private func handleLiveCapture(_ capture: LiveCapture) {
        if frameTemplate != nil, !capture.page.usedTemplate, !warnedTemplateMismatch {
            warnedTemplateMismatch = true
            infoMessage = "基準枠の向き・縦横比が現在のカメラと合わないため、このページは自動検出で取り込みました。「枠を調整」で作り直してください。"
        }
        // フレームは JPEG にしてメモリ内にだけ保持(ディスクには書かない)
        if let data = ImageUtils.jpegData(capture.frame, quality: 0.92) {
            liveFrames[capture.page.id] = data
        }
        cacheFrame(capture.frame, for: capture.page)
        pages.append(capture.page)
        refreshThumbnail(for: capture.page, frame: capture.frame)
        liveFlash = true
        Task { try? await Task.sleep(nanoseconds: 250_000_000); liveFlash = false }
    }

    // MARK: ページ操作
    func updateQuad(_ id: UUID, _ quad: Quad) {
        guard let i = index(of: id) else { return }
        pages[i].quad = quad.clamped(to: pages[i].frameSize)
        scheduleThumbnailRefresh(for: pages[i], delay: 0.35)
    }

    func updateSpine(_ id: UUID, _ spine: Spine?) {
        guard let i = index(of: id) else { return }
        pages[i].spine = spine?.clamped(to: pages[i].frameSize)
        scheduleThumbnailRefresh(for: pages[i], delay: 0.35)
    }

    /// のど線の有無を切り替える(付けるときは外枠の中央に置く)
    func toggleSpine(_ id: UUID) {
        guard let p = page(id) else { return }
        updateSpine(id, p.spine == nil ? Spine.centered(in: p.quad) : nil)
    }

    func setFullFrame(_ id: UUID) {
        guard let i = index(of: id) else { return }
        pages[i].quad = Quad.fullFrame(pages[i].frameSize)
        pages[i].spine = nil
        pages[i].confidence = nil
        scheduleThumbnailRefresh(for: pages[i], delay: 0)
    }

    func redetect(_ id: UUID) {
        guard let p = page(id) else { return }
        Task {
            do {
                let frame = try await frame(for: p)
                let detected = try await Task.detached(priority: .userInitiated) { [minimum = analysisSettings.minimumPageSize] in
                    try PageDetector.detect(in: frame, minimumSize: minimum)
                }.value
                guard let i = index(of: id) else { return }
                if let detected {
                    pages[i].quad = detected.quad
                    pages[i].spine = detected.spine
                    pages[i].confidence = detected.confidence
                    scheduleThumbnailRefresh(for: pages[i], delay: 0)
                } else {
                    infoMessage = "ページの枠を検出できませんでした。手動で四隅を調整してください。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// このページの枠+のど線を基準枠にする: 既存の全ページに適用し、以降の取り込みにも(検出なしで)使う
    func applyQuadToAll(from id: UUID) {
        guard let src = page(id) else { return }
        for i in pages.indices where pages[i].id != id {
            pages[i].quad = src.quad.scaled(from: src.frameSize, to: pages[i].frameSize)
            pages[i].spine = src.spine?.scaled(from: src.frameSize, to: pages[i].frameSize)
            pages[i].usedTemplate = true
            scheduleThumbnailRefresh(for: pages[i], delay: 0)
        }
        frameTemplate = FrameTemplate(quad: src.quad, spine: src.spine, frameSize: src.frameSize)
        infoMessage = "この枠を基準枠にしました。既存の \(pages.count) ページに適用し、以降の取り込みにもこの枠を使います(枠検出は行いません)。解除はカメラ画面またはこのページの「基準枠を解除」から。"
    }

    /// 基準枠を解除して、以降は自動検出に戻す
    func clearFrameTemplate() {
        frameTemplate = nil
        skipCalibration = true      // 解除後は自動検出でそのまま続けられる
        infoMessage = "基準枠を解除しました。以降の取り込みは自動検出になります。"
    }

    func toggleInclude(_ id: UUID) {
        guard let i = index(of: id) else { return }
        pages[i].isIncluded.toggle()
    }

    func excludeSimilarPages() {
        var n = 0
        for i in pages.indices where isSimilarToPrevious(pages[i]) && pages[i].isIncluded {
            pages[i].isIncluded = false
            n += 1
        }
        infoMessage = n > 0 ? "前ページと酷似する \(n) ページを除外しました。" : "酷似ページはありませんでした。"
    }

    func delete(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let wasSelected = selectedPageID == id
        pages.remove(at: i)
        thumbnails[id] = nil
        liveFrames[id] = nil
        frameCache.removeObject(forKey: id.uuidString as NSString)
        if wasSelected {
            selectedPageID = pages.indices.contains(i) ? pages[i].id : pages.last?.id
        }
        if pages.isEmpty && !isLive { phase = .empty }
    }

    // MARK: フレーム取得
    private func cacheKey(_ page: CapturedPage) -> NSString {
        page.id.uuidString as NSString
    }

    private func cacheFrame(_ frame: CGImage, for page: CapturedPage) {
        frameCache.setObject(frame, forKey: cacheKey(page), cost: frame.bytesPerRow * frame.height)
    }

    /// ページのフル解像度フレーム(メモリ内 JPEG からデコード)
    func frame(for page: CapturedPage) async throws -> CGImage {
        if let c = frameCache.object(forKey: cacheKey(page)) { return c }
        guard let data = liveFrames[page.id] else { throw PageDetectorError.cropFailed }
        guard let img = await Task.detached(priority: .userInitiated, operation: { ImageUtils.image(fromEncoded: data) }).value else {
            throw PageDetectorError.cropFailed
        }
        cacheFrame(img, for: page)
        return img
    }

    /// 切り出し結果(台形補正済み)
    func croppedImage(for page: CapturedPage) async throws -> CGImage {
        let frame = try await frame(for: page)
        let quad = page.quad, spine = page.spine
        return try await Task.detached(priority: .userInitiated) {
            try PageDetector.crop(frame, to: quad, spine: spine)
        }.value
    }

    /// 切り出し + 補正(紙面均一化・指除去)の結果
    func enhancedImage(for page: CapturedPage) async throws -> EnhanceResult {
        let cropped = try await croppedImage(for: page)
        let settings = enhanceSettings
        return try await Task.detached(priority: .userInitiated) {
            try PageEnhancer.enhance(cropped, settings: settings)
        }.value
    }

    private func refreshThumbnail(for page: CapturedPage, frame: CGImage) {
        let quad = page.quad, spine = page.spine
        let id = page.id
        thumbnailTasks[id]?.cancel()
        thumbnailTasks[id] = Task.detached(priority: .utility) { [weak self] in
            let img = (try? PageDetector.crop(frame, to: quad, spine: spine)) ?? frame
            let thumb = ImageUtils.resized(img, maxDimension: 320)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.thumbnails[id] = thumb }
        }
    }

    private func scheduleThumbnailRefresh(for page: CapturedPage, delay: Double) {
        let id = page.id
        thumbnailTasks[id]?.cancel()
        thumbnailTasks[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, let current = self.page(id) else { return }
            guard let frame = try? await self.frame(for: current) else { return }
            let quad = current.quad, spine = current.spine
            let thumb = await Task.detached(priority: .utility) {
                ImageUtils.resized((try? PageDetector.crop(frame, to: quad, spine: spine)) ?? frame, maxDimension: 320)
            }.value
            guard !Task.isCancelled else { return }
            self.thumbnails[id] = thumb
        }
    }

    // MARK: 書き出しと破棄
    /// 書き出しパイプライン: 1 ページずつ「展開 → クロップ → 補正 → 見開き分割 → OCR → PDF に追記」。
    /// 全ページを同時に展開しないので、ページ数が増えてもメモリはほぼ一定。
    func exportPDF() {
        let targets = includedPages
        guard !targets.isEmpty else { return }
        var jobs: [ExportJob] = []
        var missing = 0
        for p in targets {
            if let data = liveFrames[p.id] {
                jobs.append(ExportJob(frameJPEG: data, page: p))
            } else {
                missing += 1
            }
        }
        guard !jobs.isEmpty else {
            errorMessage = "書き出せるページ画像が見つかりませんでした。"
            return
        }
        if missing > 0 {
            infoMessage = "\(missing) ページの画像が見つからなかったため除外しました。"
        }

        phase = .exporting(0, "準備中…")
        exportStartedAt = Date()
        let enhance = enhanceSettings
        let ocr = ocrSettings
        let export = exportSettings
        exportTask = Task { [weak self] in
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try PDFPipeline.build(jobs: jobs, enhance: enhance, ocr: ocr, export: export) { p in
                        Task { @MainActor [weak self] in
                            guard let self, case .exporting = self.phase else { return }
                            self.phase = .exporting(p.fraction, p.message)
                        }
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                self.exportedDocument = PDFFile(data: output.pdf)
                if output.hasText {
                    let title = export.title ?? (self.suggestedPDFName as NSString).deletingPathExtension
                    self.exportedPageTexts = output.pageTexts
                    self.exportedTitle = title
                    self.exportedMarkdown = MarkdownFile(text: output.markdown(title: title, generatedAt: Date(),
                                                                               source: self.suggestedPDFName))
                } else {
                    self.exportedPageTexts = []
                    self.exportedTitle = nil
                    self.exportedMarkdown = nil
                }
                // 生成はここで完了。以降はプレビューシートの状態で管理する
                self.phase = .ready
                self.exportStartedAt = nil
                self.isShowingPDFPreview = true
            } catch is CancellationError {
                self?.phase = .ready
            } catch {
                self?.phase = .ready
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportedDocument = nil
        exportedMarkdown = nil
        pendingFile = nil
        phase = .ready
    }

    /// プレビューシートが閉じられたとき(保存後・破棄・スワイプで閉じた場合すべて)。
    /// PDF を保存済みなら、ここで取り込んだ途中データを破棄する(ポリシー)。
    func previewDismissed() {
        pendingFile = nil
        let pdfName = savedPDFName
        let mdName = savedMarkdownName
        let fullDiscard = pendingFullDiscard
        pendingFullDiscard = false
        exportedDocument = nil
        exportedMarkdown = nil
        savedPDFName = nil
        savedMarkdownName = nil
        if case .exporting = phase { phase = .ready }

        if fullDiscard {
            // カメラも止めて最初の画面へ
            discardSession()
            return
        }
        guard let pdfName else { return }

        let count = includedPages.count
        discardSession(keepLive: true)
        // シートが閉じ切ってからアラートを出す(閉じる途中だと表示されないことがある)
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            var text = "\(count) ページを \(pdfName) に書き出しました。"
            if let mdName { text += "テキストは \(mdName) に保存済みです。" }
            text += "取り込んだ途中データはすべて破棄しました。"
            infoMessage = text
        }
    }

    /// プレビューを破棄(PDF は捨てるが、取り込んだページは残す)
    /// 「破棄」: 生成した PDF も取り込んだページもすべて捨てて、最初の画面に戻る
    func discardExportedPDF() {
        savedPDFName = nil
        pendingFullDiscard = true
        isShowingPDFPreview = false
    }

    /// 「PDF を保存」
    func requestSavePDF() {
        guard let doc = exportedDocument else { return }
        pendingFile = ExportableFile(data: doc.data)
        pendingFileType = .pdf
        pendingFileName = suggestedPDFName
        pendingKind = .pdf
        isShowingExporter = true
    }

    /// 「テキスト (.md) を保存」
    func requestSaveMarkdown() {
        guard exportedMarkdown != nil else { return }
        // 実際に保存した PDF 名(まだなら提案名)を出典として各ページ見出しに埋め込む。
        // RAG(Foundry の file search など)の引用から、正解である PDF のページ画像へ辿れるようにするため。
        let pdfName = savedPDFName ?? suggestedPDFName
        let text = MarkdownExporter.document(title: exportedTitle, pages: exportedPageTexts,
                                             generatedAt: Date(), source: pdfName)
        exportedMarkdown = MarkdownFile(text: text)
        pendingFile = ExportableFile(data: Data(text.utf8))
        pendingFileType = MarkdownFile.markdownType
        pendingFileName = (pdfName as NSString).deletingPathExtension + ".md"
        pendingKind = .markdown
        isShowingExporter = true
    }

    /// 保存ダイアログの完了。ここではまだ破棄しない(PDF と .md の両方を保存できるようにするため)。
    /// 破棄はプレビューを閉じたときに行う。
    func exportFinished(_ result: Result<URL, Error>) {
        let kind = pendingKind
        pendingFile = nil
        switch result {
        case .success(let url):
            switch kind {
            case .pdf:
                savedPDFName = url.lastPathComponent
                // PDF は「正解」、.md は「索引」。RAG には両方入れる前提なので、PDF を保存したら
                // 続けて同名の .md も保存するよう促す(キャンセル可)。ダイアログは 1 つを使い回すので、
                // 前のシートが閉じ切ってから出す。
                if exportedMarkdown != nil, savedMarkdownName == nil {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard let self, self.isShowingPDFPreview, self.savedMarkdownName == nil else { return }
                        self.requestSaveMarkdown()
                    }
                }
            case .markdown: savedMarkdownName = url.lastPathComponent
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// 保存ダイアログを閉じただけ(生成した PDF / .md は保持したまま)
    func exportCancelled() {
        pendingFile = nil
    }

    /// ページ・フレーム・サムネイルなど途中データをすべて捨てる。
    /// keepLive が true ならカメラは動かしたまま次の取り込みを受け付ける。
    func discardSession(keepLive: Bool = false) {
        discardPages()
        if isLive && keepLive {
            liveScanner?.resetHistory()
            suggestedPDFName = "scan-\(Self.dateStamp()).pdf"
            phase = .ready
            return
        }
        stopLive(clearPages: true)
        phase = .empty
    }

    private func discardPages() {
        for t in thumbnailTasks.values { t.cancel() }
        thumbnailTasks.removeAll()
        pages.removeAll()
        thumbnails.removeAll()
        liveFrames.removeAll()
        frameCache.removeAllObjects()
        selectedPageID = nil
        exportedDocument = nil
        exportedMarkdown = nil
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
