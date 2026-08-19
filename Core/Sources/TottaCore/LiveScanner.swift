import Foundation
import CoreGraphics
import CoreImage
@preconcurrency import AVFoundation

/// ライブカメラで取り込まれた1ページ。
/// ポリシー: カメラ映像はどこにも保存しない。ここで渡すフレームはメモリ上のオブジェクトのみで、ディスクには書かない。
public struct LiveCapture: Sendable {
    public let page: CapturedPage
    public let frame: CGImage
}

public struct LiveState: Sendable, Equatable {
    public enum Motion: Sendable, Equatable {
        case idle
        case moving
        case settling(Double)
        case held
    }
    public var motion: Motion = .idle
    public var capturedCount: Int = 0
    public var isRunning: Bool = false
    /// 自動取り込みが有効か(false ならプレビューのみ)
    public var isArmed: Bool = false
    /// ピント・露出・ホワイトバランスを固定済みか
    public var isFocusLocked: Bool = false
    /// 使用中の映像フォーマット(例 "3840×2160 30fps")
    public var formatDescription: String = ""
    /// 直近に解析したフレームのピクセルサイズ(回転適用後)
    public var frameSize: CGSize = .zero
    /// 現在のズーム倍率と可能範囲
    public var zoomFactor: CGFloat = 1
    public var minZoom: CGFloat = 1
    public var maxZoom: CGFloat = 1
    public var lastEventTime: Double = 0
    public init() {}
}

public enum LiveScannerError: Error, LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case accessDenied
    public var errorDescription: String? {
        switch self {
        case .noCamera: return "使用できるカメラがありません"
        case .cannotAddInput: return "カメラ入力を追加できません"
        case .cannotAddOutput: return "カメラ出力を追加できません"
        case .accessDenied: return "カメラへのアクセスが許可されていません"
        }
    }
}

/// カメラ映像を録画せずに逐次解析し、静止したページだけを取り込む。
/// AVCaptureMovieFileOutput は使わず、フレームはメモリ上でのみ扱う。
public final class LiveScanner: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "totta.live.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var _settings: AnalysisSettings
    private var tracker: StillnessTracker
    private var lastSampleTime: Double = -1
    private var startTime: Double?
    private var duplicateFilter = DuplicateFilter()
    private var manualCaptureRequested = false
    private var stillRequest: (@Sendable (CGImage) -> Void)?
    private var armed = false
    private var _template: FrameTemplate?
    private var capturedCount = 0
    private var lastReportedState = LiveState()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var videoOutput: AVCaptureVideoDataOutput?
    /// 現在使っているカメラ(回転制御などのために公開)
    public private(set) var device: AVCaptureDevice?

    /// 取り込みが発生したときに呼ばれる(バックグラウンドキュー)
    public var onCapture: (@Sendable (LiveCapture) -> Void)?
    /// 状態が変わったときに呼ばれる(バックグラウンドキュー)
    public var onState: (@Sendable (LiveState) -> Void)?

    public var settings: AnalysisSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set {
            lock.lock()
            _settings = newValue
            tracker.motionThreshold = newValue.motionThreshold
            tracker.minStillDuration = newValue.minStillDuration
            lock.unlock()
        }
    }

    /// 基準枠。設定すると以降の取り込みは枠検出をせずにこれを使う
    public var template: FrameTemplate? {
        get { lock.lock(); defer { lock.unlock() }; return _template }
        set { lock.lock(); _template = newValue; lock.unlock() }
    }

    public init(settings: AnalysisSettings) {
        _settings = settings
        tracker = StillnessTracker(motionThreshold: settings.motionThreshold, minStillDuration: settings.minStillDuration)
        super.init()
    }

    // MARK: - Devices

    public static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        #if os(macOS)
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        }
        #else
        types.append(contentsOf: [.builtInUltraWideCamera, .builtInTelephotoCamera])
        #endif
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        // 背面カメラを先に(iPhone/iPad で既定にするため)
        return discovery.devices.sorted { a, b in
            (a.position == .back ? 0 : 1) < (b.position == .back ? 0 : 1)
        }
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Session

    /// カメラを設定する。deviceID が nil ならデフォルトカメラ。
    public func configure(deviceID: String? = nil) throws {
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = Self.availableCameras().first ?? AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw LiveScannerError.noCamera }
        self.device = device

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw LiveScannerError.cannotAddInput }
        session.addInput(input)

        // プリセットではなく、デバイスが持つ最高解像度のフォーマット(30fps 以上)を選ぶ
        var formatText = ""
        if let best = Self.bestFormat(for: device) {
            #if os(iOS)
            session.sessionPreset = .inputPriority
            #endif
            do {
                try device.lockForConfiguration()
                device.activeFormat = best
                let fps = min(30.0, best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.unlockForConfiguration()
                let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                formatText = "\(dims.width)×\(dims.height) \(Int(fps))fps"
            } catch {
                for preset in [AVCaptureSession.Preset.hd4K3840x2160, .hd1920x1080, .high] where session.canSetSessionPreset(preset) {
                    session.sessionPreset = preset
                    break
                }
            }
        } else {
            for preset in [AVCaptureSession.Preset.hd4K3840x2160, .hd1920x1080, .high] where session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw LiveScannerError.cannotAddOutput }
        session.addOutput(output)
        videoOutput = output
        let (zmin, zmax, znow) = Self.zoomInfo(device)
        report {
            $0.isFocusLocked = false
            $0.formatDescription = formatText
            $0.minZoom = zmin; $0.maxZoom = zmax; $0.zoomFactor = znow
        }
    }

    /// 30fps 以上出せるフォーマットのうち最大画素数のもの(上限 ~12.6MP、8K 級の写真用フォーマットは避ける)
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let maxPixels: Int32 = 4096 * 3072
        var best: (AVCaptureDevice.Format, Int32)? = nil
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let pixels = dims.width * dims.height
            guard pixels <= maxPixels else { continue }
            guard f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) else { continue }
            let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            // 8bit 4:2:0 を優先(BGRA 変換が軽い)。10bit(x420)などは同画素数なら後回し
            let preferred = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let score = pixels * 2 + (preferred ? 1 : 0)
            if best == nil || score > best!.1 { best = (f, score) }
        }
        return best?.0
    }

    // MARK: - Zoom

    static func zoomInfo(_ device: AVCaptureDevice) -> (CGFloat, CGFloat, CGFloat) {
        #if os(iOS)
        let maxZ = min(device.activeFormat.videoMaxZoomFactor, 8)
        return (device.minAvailableVideoZoomFactor, maxZ, device.videoZoomFactor)
        #else
        return (1, 1, 1)
        #endif
    }

    /// ズーム倍率を設定(対応機種のみ)。返り値は実際に設定された値
    @discardableResult
    public func setZoom(_ factor: CGFloat) -> CGFloat {
        #if os(iOS)
        guard let device else { return 1 }
        let (zmin, zmax, _) = Self.zoomInfo(device)
        let z = min(max(factor, zmin), zmax)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = z
            device.unlockForConfiguration()
            report { $0.zoomFactor = z }
        } catch {}
        return z
        #else
        return 1
        #endif
    }

    /// 取り込むフレームの回転角(度)。iPhone を縦に持ったときなど、プレビューと揃えるために外から設定する。
    public func setVideoRotationAngle(_ angle: CGFloat) {
        guard let conn = videoOutput?.connection(with: .video), conn.isVideoRotationAngleSupported(angle) else { return }
        if conn.videoRotationAngle != angle { conn.videoRotationAngle = angle }
    }

    public func start() {
        queue.async { [self] in
            lock.lock()
            tracker.reset()
            lastSampleTime = -1
            startTime = nil
            manualCaptureRequested = false
            lock.unlock()
            if !session.isRunning { session.startRunning() }
            report { $0.isRunning = true; $0.isArmed = false; $0.motion = .idle }
        }
    }

    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            lock.lock(); armed = false; lock.unlock()
            report { $0.isRunning = false; $0.isArmed = false; $0.motion = .idle }
        }
    }

    /// 自動取り込みの開始/停止。停止中はプレビューのみで、静止しても取り込まない。
    public func setArmed(_ on: Bool) {
        lock.lock()
        armed = on
        tracker.reset()
        lock.unlock()
        report { $0.isArmed = on; $0.motion = on ? .moving : .idle }
    }

    /// 指定した点(デバイス座標 0-1)でピント・露出・ホワイトバランスを合わせ、その値で固定する。
    /// 点が nil なら現在の設定のまま一度だけ合わせて固定する。
    public func lockFocusAndExposure(atDevicePoint point: CGPoint?) throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let point {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
        }
        // 「一度だけ合わせて、その後は固定」のモード
        if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        } else if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
        } else if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
            device.whiteBalanceMode = .autoWhiteBalance
        } else if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        #if os(iOS)
        device.isSubjectAreaChangeMonitoringEnabled = false
        #endif
        report { $0.isFocusLocked = true }
    }

    /// 固定を解除して連続オートに戻す
    public func unlockFocusAndExposure() throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        report { $0.isFocusLocked = false }
    }

    /// 次のフレームを 1 枚だけ取り出す。ページとしては取り込まない(キャリブレーション用)。
    public func grabFrame(_ completion: @escaping @Sendable (CGImage) -> Void) {
        lock.lock(); stillRequest = completion; lock.unlock()
    }

    /// 次のフレームを静止判定に関係なく取り込む(自動取り込みが停止中でも使える)
    public func captureNow() {
        lock.lock(); manualCaptureRequested = true; lock.unlock()
    }

    /// 取り込み済みページの記憶(重複判定用)をリセットする。セッション破棄時に呼ぶ。
    public func resetHistory() {
        lock.lock()
        duplicateFilter.reset()
        capturedCount = 0
        lock.unlock()
        report { $0.capturedCount = 0 }
    }

    private func report(_ change: (inout LiveState) -> Void) {
        lock.lock()
        var s = lastReportedState
        change(&s)
        let changed = s != lastReportedState
        lastReportedState = s
        lock.unlock()
        if changed { onState?(s) }
    }

    // MARK: - Delegate

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard pts.isFinite, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        let still = stillRequest
        if still != nil { stillRequest = nil }
        if startTime == nil { startTime = pts }
        let elapsed = pts - (startTime ?? pts)
        let settings = _settings
        let manual = manualCaptureRequested
        manualCaptureRequested = false
        let isArmed = armed
        let template = _template
        let due = manual || lastSampleTime < 0 || pts - lastSampleTime >= settings.samplingInterval
        lock.unlock()

        let pbSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        report { $0.frameSize = pbSize }

        // キャリブレーション用の 1 枚(取り込み判定とは無関係)
        if let still, let frame = makeCGImage(pb) { still(frame) }

        guard due else { return }
        // プレビューのみ(停止中)のときは手動取り込み以外は何もしない
        if !isArmed && !manual { return }

        let fp = Fingerprint.make(from: pb, width: settings.fingerprintWidth)
        lock.lock()
        lastSampleTime = pts
        var event = tracker.feed(time: elapsed, fingerprint: fp)
        if manual {
            tracker.markCaptured()
            event = .capture
        }
        lock.unlock()

        switch event {
        case .moving:
            report { $0.motion = .moving; $0.lastEventTime = elapsed }
        case .settling(let p):
            report { $0.motion = .settling(p); $0.lastEventTime = elapsed }
        case .held:
            report { $0.motion = .held; $0.lastEventTime = elapsed }
        case .capture:
            guard let frame = makeCGImage(pb) else { return }
            let page = PageCapture.makePage(from: frame, at: elapsed, settings: settings,
                                            kind: manual ? .manual : .auto, template: template)
            let pageFP = PageCapture.pageFingerprint(frame: frame, quad: page.quad, spine: page.spine)
            lock.lock()
            var page2 = page
            let verdict = duplicateFilter.evaluate(pageFP, threshold: settings.duplicateThreshold, force: manual)
            page2.differenceFromPrevious = verdict.difference
            let skip = !verdict.keep
            if !skip { capturedCount += 1 }
            let count = capturedCount
            lock.unlock()
            report { $0.motion = .held; $0.capturedCount = count; $0.lastEventTime = elapsed }
            if !skip {
                onCapture?(LiveCapture(page: page2, frame: frame))
            }
        }
    }

    private func makeCGImage(_ pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}
