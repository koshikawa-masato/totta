import SwiftUI
import AVFoundation
import TottaCore

/// ライブカメラ画面。映像を全面に出し、操作系は OSD(重ね表示)にする。
/// 上部バーは既定で隠れていて、下スワイプ(または ⌄ ボタン)で出る。
struct LiveCaptureView: View {
    @Bindable var model: ProjectModel
    /// ページ一覧へ遷移するためのコールバック(iOS)
    var onShowPages: (() -> Void)? = nil

    #if os(macOS)
    @State private var showControls = true
    #else
    @State private var showControls = false
    #endif
    @State private var pinchStartZoom: CGFloat? = nil

    var body: some View {
        if model.calibration != nil {
            CalibrationView(model: model)
        } else {
            cameraScreen
        }
    }

    // MARK: - カメラ画面

    private var cameraScreen: some View {
        ZStack {
            Color.black
            preview
            overlays
            osd
        }
        .ignoresSafeArea(edges: .bottom)
        #if os(iOS)
        .statusBarHidden(!showControls)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        showControls = value.translation.height > 0
                    }
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchStartZoom == nil { pinchStartZoom = model.liveState.zoomFactor }
                    model.setZoom((pinchStartZoom ?? 1) * value.magnification)
                }
                .onEnded { _ in pinchStartZoom = nil }
        )
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        .onChange(of: model.liveState.isArmed) { _, armed in
            // 取り込みを始めたらバーを畳んで映像を最大化
            if armed { withAnimation(.easeOut(duration: 0.22)) { showControls = false } }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let scanner = model.liveScanner {
            CameraPreviewView(scanner: scanner,
                              onTap: { devicePoint, layerPoint in
                                  model.lockFocus(devicePoint: devicePoint, layerPoint: layerPoint)
                              },
                              lockLandscape: model.lockLandscape)
        }
    }

    /// 映像に重なる表示(基準枠・ピント枠・取り込みフラッシュ)
    @ViewBuilder
    private var overlays: some View {
        if let t = model.frameTemplate, model.templateMatchesCurrentFrame {
            TemplateOverlay(template: t)
                .allowsHitTesting(false)
        }
        if let p = model.focusReticle {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 72, height: 72)
                .position(p)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
        if model.liveFlash {
            Color.white.opacity(0.7)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - OSD

    private var osd: some View {
        ZStack(alignment: .top) {
            // 左右の余白(4:3 映像の黒帯)に置くので映像に被りにくい
            HStack(alignment: .center, spacing: 0) {
                leftColumn
                Spacer(minLength: 0)
                rightColumn
            }
            .padding(.horizontal, 14)

            VStack(spacing: 6) {
                if showControls {
                    controlBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                handle
            }
            .padding(.top, showControls ? 4 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: model.liveFlash)
        .animation(.easeOut(duration: 0.2), value: model.focusReticle)
    }

    /// 上部バーの開閉ハンドル
    private var handle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) { showControls.toggle() }
        } label: {
            Image(systemName: showControls ? "chevron.compact.up" : "chevron.compact.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 56, height: 22)
                .background(.black.opacity(0.28), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(showControls ? "メニューを隠す(上スワイプ)" : "メニューを出す(下スワイプ)")
    }

    /// 下スワイプで出てくる操作バー
    private var controlBar: some View {
        HStack(spacing: 14) {
            Button { onShowPages?() } label: {
                Image(systemName: "photo.stack")
            }
            .disabled(model.pages.isEmpty || onShowPages == nil)
            .overlay(alignment: .topTrailing) {
                if !model.pages.isEmpty {
                    Text("\(model.pages.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 10, y: -8)
                }
            }

            cameraPicker
            zoomControl

            Spacer(minLength: 8)

            Button { model.liveCaptureNow() } label: {
                Image(systemName: "camera")
            }
            .disabled(!model.liveState.isRunning)
            .help("今すぐ 1 枚取り込む")

            Button { model.beginCalibration() } label: {
                Image(systemName: "viewfinder")
            }
            .disabled(model.isPreparingCalibration || !model.liveState.isRunning)
            .help("枠を合わせる")

            Button { model.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            Button { model.exportPDF() } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(model.includedPages.isEmpty || model.isBusy)
            Button { model.stopLive(clearPages: false) } label: {
                Image(systemName: "xmark")
            }
            .help("カメラを停止")
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
    }

    /// 左の余白: 状態と、取り込んだページへの入口
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            statusPill
            if let last = model.pages.last, let thumb = model.thumbnails[last.id] {
                Button {
                    onShowPages?()
                } label: {
                    VStack(spacing: 4) {
                        Image(decorative: thumb, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 92, height: 62)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.5), lineWidth: 1))
                        Label("\(model.pages.count) ページ", systemImage: "chevron.right")
                            .labelStyle(TrailingIconLabelStyle())
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(onShowPages == nil)
                .help("ページ一覧を開く(ここから PDF にできます)")
            }
            Spacer(minLength: 0)
        }
    }

    /// 右の余白: ボタン 1 つだけ(未キャリブレーションなら「枠を合わせる」、以降は開始/停止)
    private var rightColumn: some View {
        VStack {
            Spacer(minLength: 0)
            mainButton
            Spacer(minLength: 0)
        }
    }

    /// 唯一の主ボタン(シャッター風の赤ボタン)。
    /// キャリブレーション前は同じ位置・同じ大きさで枠合わせボタンになる。
    private var mainButton: some View {
        let armed = model.liveState.isArmed
        let ready = model.canStartCapture
        return Button {
            if ready { model.toggleCapturing() } else { model.beginCalibration() }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 68, height: 68)
                if model.isPreparingCalibration {
                    ProgressView().controlSize(.small).tint(.white)
                } else if !ready {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                } else if armed {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 55, height: 55)
                }
            }
            .shadow(radius: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!model.liveState.isRunning || model.isPreparingCalibration)
        .animation(.easeOut(duration: 0.15), value: armed)
        .accessibilityLabel(ready ? (armed ? "自動取り込みを停止" : "自動取り込みを開始") : "枠を合わせる")
    }

    /// 状態(ピント固定・動き・ページ数)を 1 つにまとめた小さな表示
    private var statusPill: some View {
        let s = model.liveState
        return HStack(spacing: 6) {
            Image(systemName: s.isFocusLocked ? "lock.fill" : "lock.open")
                .foregroundStyle(s.isFocusLocked ? .green : .white.opacity(0.7))
            switch s.motion {
            case .idle:
                Image(systemName: "pause.circle").foregroundStyle(.white.opacity(0.7))
            case .moving:
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .settling(let p):
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).tint(.white)
            case .held:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if !model.pages.isEmpty {
                Text("\(model.pages.count)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
        .help(statusText)
    }

    private var statusText: String {
        let s = model.liveState
        switch s.motion {
        case .idle: return s.isArmed ? "待機中" : "プレビューのみ"
        case .moving: return "動きを検出中"
        case .settling: return "静止判定中…"
        case .held: return "取り込み済み — ページをめくってください"
        }
    }

    // MARK: - パーツ

    @ViewBuilder
    private var cameraPicker: some View {
        if model.availableCameras.count > 1 {
            Picker("カメラ", selection: Binding(
                get: { model.selectedCameraID ?? "" },
                set: { model.switchCamera(to: $0) })) {
                ForEach(model.availableCameras, id: \.id) { cam in
                    Text(cam.name).tag(cam.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder
    private var zoomControl: some View {
        let st = model.liveState
        if st.maxZoom > st.minZoom + 0.05 {
            HStack(spacing: 6) {
                Slider(value: Binding(get: { Double(st.zoomFactor) }, set: { model.setZoom(CGFloat($0)) }),
                       in: Double(st.minZoom)...Double(st.maxZoom))
                    .frame(width: 120)
                Text(String(format: "%.1f×", st.zoomFactor))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }


}

/// アイコンを右に置くラベル
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 9, weight: .bold))
        }
    }
}

/// 基準枠をプレビューに重ねて描く。プレビューは aspect-fit なので、フレームの縦横比で描画領域を求める
struct TemplateOverlay: View {
    let template: FrameTemplate
    var body: some View {
        GeometryReader { geo in
            let fit = QuadEditor.fitRect(template.frameSize, in: geo.size)
            let sx = fit.width / template.frameSize.width
            let sy = fit.height / template.frameSize.height
            let pts = template.quad.points.map { CGPoint(x: fit.minX + $0.x * sx, y: fit.minY + $0.y * sy) }
            Path { path in
                path.addLines(pts)
                path.closeSubpath()
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            if let sp = template.spine {
                let top = CGPoint(x: fit.minX + sp.top.x * sx, y: fit.minY + sp.top.y * sy)
                let bottom = CGPoint(x: fit.minX + sp.bottom.x * sx, y: fit.minY + sp.bottom.y * sy)
                Path { path in path.move(to: top); path.addLine(to: bottom) }
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
    }
}

#if os(macOS)
import AppKit

struct CameraPreviewView: NSViewRepresentable {
    let scanner: LiveScanner
    /// タップ位置(デバイス座標 0-1, レイヤー座標)
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil
    /// macOS では映像の向きは変わらないので使わない
    var lockLandscape: Bool = true

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.previewLayer.session = scanner.session
        v.onTap = onTap
        return v
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== scanner.session { nsView.previewLayer.session = scanner.session }
        nsView.onTap = onTap
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var onTap: ((CGPoint, CGPoint) -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspect
            previewLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
            layer = previewLayer
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:))))
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func handleClick(_ g: NSClickGestureRecognizer) {
            let p = g.location(in: self)   // AppKit は左下原点
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: convertToLayer(p))
            // SwiftUI 側(左上原点)の座標に直して返す
            onTap?(devicePoint, CGPoint(x: p.x, y: bounds.height - p.y))
        }
    }
}
#else
import UIKit

/// iOS: AVCaptureDevice.RotationCoordinator でプレビューと取り込みフレームの向きを端末の持ち方に追従させる
struct CameraPreviewView: UIViewRepresentable {
    let scanner: LiveScanner
    /// タップ位置(デバイス座標 0-1, レイヤー座標)
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil
    /// 端末が縦でも映像を横向き(見開き向き)のまま扱う
    var lockLandscape: Bool = true

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = scanner.session
        v.onTap = onTap
        v.lockLandscape = lockLandscape
        v.attach(scanner: scanner)
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== scanner.session { uiView.previewLayer.session = scanner.session }
        uiView.onTap = onTap
        uiView.lockLandscape = lockLandscape
        uiView.attach(scanner: scanner)
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var lockLandscape: Bool = true {
            didSet { if lockLandscape != oldValue { applyAngles() } }
        }
        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observations: [NSKeyValueObservation] = []
        private weak var scanner: LiveScanner?
        private var attachedDeviceID: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            previewLayer.videoGravity = .resizeAspect
            backgroundColor = .black
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            onTap?(devicePoint, p)
        }

        func attach(scanner: LiveScanner) {
            guard let device = scanner.device, device.uniqueID != attachedDeviceID else { return }
            self.scanner = scanner
            attachedDeviceID = device.uniqueID
            observations.removeAll()
            let c = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            coordinator = c
            applyAngles()
            observations.append(c.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyAngles() }
            })
            observations.append(c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyAngles() }
            })
        }

        /// プレビューと取り込みフレームに同じ角度を適用する。
        /// 同じ角度にしておくと、プレビュー上の基準枠と実際の切り出しが一致する。
        private func applyAngles() {
            guard let c = coordinator else { return }
            let raw = c.videoRotationAngleForHorizonLevelCapture
            let angle = lockLandscape ? Self.landscapeAngle(raw) : raw
            if let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            scanner?.setVideoRotationAngle(angle)
        }

        /// 端末の向きに対応する角度を、いちばん近い横向き(0° / 180°)に丸める
        static func landscapeAngle(_ a: CGFloat) -> CGFloat {
            switch a {
            case 90: return 0        // 縦持ち → センサー本来の横向き
            case 270: return 180     // 上下逆の縦持ち
            default: return a        // 0 / 180 はすでに横向き
            }
        }
    }
}
#endif
