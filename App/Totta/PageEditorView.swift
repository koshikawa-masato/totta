import SwiftUI
import TottaCore

struct PageEditorView: View {
    enum Mode: Hashable { case edit, preview, enhanced }

    @Bindable var model: ProjectModel
    let page: CapturedPage
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    @State private var frame: CGImage?
    @State private var mode: Mode = .edit
    @State private var cropped: CGImage?
    @State private var enhanced: EnhanceResult?
    @State private var loadError: String?

    private var quadBinding: Binding<Quad> {
        Binding(
            get: { model.page(page.id)?.quad ?? page.quad },
            set: { model.updateQuad(page.id, $0) }
        )
    }
    private var spineBinding: Binding<Spine?> {
        Binding(
            get: { model.page(page.id)?.spine ?? page.spine },
            set: { model.updateSpine(page.id, $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black.opacity(0.03)
                if let frame {
                    if mode == .edit {
                        QuadEditor(image: frame, quad: quadBinding, spine: spineBinding)
                            .padding(16)
                    } else if mode == .preview, let cropped {
                        Image(decorative: cropped, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(16)
                    } else if mode == .enhanced, let enhanced {
                        Image(decorative: enhanced.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(16)
                    } else {
                        ProgressView()
                    }
                } else if let loadError {
                    ContentUnavailableView("フレームを読み込めません", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView()
                }
            }
            Divider()
            footer
        }
        .task(id: page.id) {
            frame = nil
            cropped = nil
            loadError = nil
            do {
                frame = try await model.frame(for: page)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .task(id: PreviewKey(id: page.id, quad: page.quad, spine: page.spine, mode: mode, hasFrame: frame != nil, enhance: model.enhanceSettings)) {
            guard frame != nil else { return }
            switch mode {
            case .edit:
                break
            case .preview:
                cropped = try? await model.croppedImage(for: page)
            case .enhanced:
                enhanced = nil
                enhanced = try? await model.enhancedImage(for: page)
            }
        }
    }

    private struct PreviewKey: Hashable {
        let id: UUID
        let quad: Quad
        let spine: Spine?
        let mode: Mode
        let hasFrame: Bool
        let enhance: EnhanceSettings
        static func == (a: PreviewKey, b: PreviewKey) -> Bool {
            a.id == b.id && a.quad == b.quad && a.spine == b.spine && a.mode == b.mode && a.hasFrame == b.hasFrame && a.enhance == b.enhance
        }
        func hash(into h: inout Hasher) {
            h.combine(id); h.combine(quad); h.combine(spine); h.combine(mode); h.combine(hasFrame)
            h.combine(enhance.flattenLighting); h.combine(enhance.removeFingers); h.combine(enhance.grayscale)
            h.combine(enhance.blackPoint); h.combine(enhance.whitePoint)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("表示", selection: $mode) {
                Text("枠を編集").tag(Mode.edit)
                Text("切り出し").tag(Mode.preview)
                Text("補正後").tag(Mode.enhanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer()

            if isCompact {
                Menu {
                    Button { model.redetect(page.id) } label: { Label("枠を再検出", systemImage: "viewfinder") }
                    Button { model.setFullFrame(page.id) } label: { Label("枠を全体に", systemImage: "rectangle") }
                    Button { model.applyQuadToAll(from: page.id) } label: { Label("この枠を基準枠にする(全ページ+以降に適用)", systemImage: "square.on.square") }
                    if model.frameTemplate != nil {
                        Button { model.clearFrameTemplate() } label: { Label("基準枠を解除", systemImage: "square.slash") }
                    }
                    Button { model.toggleSpine(page.id) } label: {
                        Label((model.page(page.id)?.spine != nil) ? "のど線を外す(1 枚として補正)" : "のど線を付ける(左右別に補正)",
                              systemImage: "rectangle.split.2x1")
                    }
                    Divider()
                    Button { model.toggleInclude(page.id) } label: {
                        Label((model.page(page.id)?.isIncluded ?? true) ? "PDF から除外" : "PDF に含める",
                              systemImage: (model.page(page.id)?.isIncluded ?? true) ? "eye.slash" : "eye")
                    }
                    Button(role: .destructive) { model.delete(page.id) } label: { Label("削除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
            Button {
                model.redetect(page.id)
            } label: {
                Label("再検出", systemImage: "viewfinder")
            }
            .help("Vision でページの枠を検出し直します")

            Button {
                model.setFullFrame(page.id)
            } label: {
                Label("全体", systemImage: "rectangle")
            }
            .help("枠をフレーム全体に戻します")

            Button {
                model.applyQuadToAll(from: page.id)
            } label: {
                Label("基準枠にする", systemImage: "square.on.square")
            }
            .help("この枠+のど線を基準枠として保存し、既存の全ページと以降の取り込みに適用します(カメラ固定向け。以降は枠検出を行いません)")
            if model.frameTemplate != nil {
                Button {
                    model.clearFrameTemplate()
                } label: {
                    Label("基準枠を解除", systemImage: "square.slash")
                }
                .help("以降の取り込みを自動検出に戻します")
            }

            Toggle(isOn: Binding(get: { model.page(page.id)?.spine != nil },
                                 set: { _ in model.toggleSpine(page.id) })) {
                Label("のど線", systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .help("見開きの左右ページを別々に台形補正します。オレンジのハンドルでのど(中央の折れ目)の位置を合わせてください")

            Toggle(isOn: Binding(get: { model.page(page.id)?.isIncluded ?? true },
                                 set: { _ in model.toggleInclude(page.id) })) {
                Text("PDF に含める")
            }
            .toggleStyle(.switch)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerItems(spacing: 16)
            ScrollView(.horizontal, showsIndicators: false) { footerItems(spacing: 12) }
        }
    }

    private func footerItems(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if let n = model.outputNumber(of: page.id) {
                Text("出力 p.\(n)")
            } else {
                Text("除外中").foregroundStyle(.secondary)
            }
            Text("取り込み \(Fmt.time(page.time))")
            if let d = page.stillDuration {
                Text(String(format: "静止 %.1f 秒", d))
            }
            if let c = page.confidence {
                Text(String(format: "検出信頼度 %.0f%%", c * 100))
            } else {
                Text("枠: 手動 / 全体").foregroundStyle(.orange)
            }
            let size = page.quad.correctedSize
            Text("切り出し \(Int(size.width))×\(Int(size.height)) px")
            if page.spine != nil {
                Text("見開き: 左右別補正").foregroundStyle(.blue)
            }
            if page.usedTemplate {
                Text("基準枠を適用").foregroundStyle(.blue)
            }
            if let d = page.differenceFromPrevious {
                Text(String(format: "前ページとの差 %.1f", d))
                    .foregroundStyle(model.isSimilarToPrevious(page) ? .orange : .secondary)
            }
            if mode == .enhanced, let enhanced {
                if enhanced.fingerCoverage > 0 {
                    Text(String(format: "指を除去 %.1f%%", enhanced.fingerCoverage * 100))
                        .foregroundStyle(.orange)
                } else if model.enhanceSettings.removeFingers {
                    Text("指なし")
                }
            }
            Spacer()
            if model.isLive, !isCompact {
                Button {
                    model.selectedPageID = nil
                } label: {
                    Label("カメラに戻る", systemImage: "video")
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// 画像の上に四角形を重ね、四隅をドラッグで編集する。
struct QuadEditor: View {
    let image: CGImage
    @Binding var quad: Quad
    var spine: Binding<Spine?>? = nil

    @State private var dragStartQuad: Quad?
    @State private var dragStartSpine: Spine?
    private let handleRadius: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let imageSize = CGSize(width: image.width, height: image.height)
            let fit = Self.fitRect(imageSize, in: geo.size)
            let scale = fit.width / imageSize.width

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)

                // 枠の外側を薄く暗くする
                Path { p in
                    p.addRect(fit)
                    p.addLines(quad.points.map { toView($0, fit: fit, scale: scale) })
                    p.closeSubpath()
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // 枠
                Path { p in
                    let pts = quad.points.map { toView($0, fit: fit, scale: scale) }
                    p.addLines(pts)
                    p.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 2)
                .contentShape(Path { p in
                    p.addLines(quad.points.map { toView($0, fit: fit, scale: scale) })
                    p.closeSubpath()
                })
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("editor"))
                        .onChanged { value in
                            if dragStartQuad == nil { dragStartQuad = quad; dragStartSpine = spine?.wrappedValue }
                            guard let start = dragStartQuad else { return }
                            let dx = value.translation.width / scale
                            let dy = value.translation.height / scale
                            quad = start.translated(by: CGVector(dx: dx, dy: dy)).clamped(to: imageSize)
                            if let s = dragStartSpine {
                                spine?.wrappedValue = s.translated(by: CGVector(dx: dx, dy: dy)).clamped(to: imageSize)
                            }
                        }
                        .onEnded { _ in dragStartQuad = nil; dragStartSpine = nil }
                )

                // のど線(左右ページの境界)
                if let spineBinding = spine, let sp = spineBinding.wrappedValue {
                    let top = toView(sp.top, fit: fit, scale: scale)
                    let bottom = toView(sp.bottom, fit: fit, scale: scale)
                    Path { p in p.move(to: top); p.addLine(to: bottom) }
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                    ForEach([0, 1], id: \.self) { which in
                        let vp = which == 0 ? top : bottom
                        Circle()
                            .fill(Color.orange)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .frame(width: handleRadius * 2, height: handleRadius * 2)
                            .contentShape(Circle().scale(2.2))
                            .position(vp)
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                                    .onChanged { value in
                                        var s = sp
                                        let p = toImage(value.location, fit: fit, scale: scale, imageSize: imageSize)
                                        if which == 0 { s.top = p } else { s.bottom = p }
                                        spineBinding.wrappedValue = s
                                    }
                            )
                    }
                }

                // 四隅ハンドル
                ForEach(Quad.Corner.allCases, id: \.self) { corner in
                    let vp = toView(quad[corner], fit: fit, scale: scale)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: handleRadius * 2, height: handleRadius * 2)
                        .contentShape(Circle().scale(2.2))
                        .position(vp)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                                .onChanged { value in
                                    var q = quad
                                    q[corner] = toImage(value.location, fit: fit, scale: scale, imageSize: imageSize)
                                    quad = q
                                }
                        )
                        #if os(macOS)
                        .onHover { inside in
                            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                        #endif
                }
            }
            .coordinateSpace(name: "editor")
        }
    }

    private func toView(_ p: CGPoint, fit: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: fit.minX + p.x * scale, y: fit.minY + p.y * scale)
    }

    private func toImage(_ p: CGPoint, fit: CGRect, scale: CGFloat, imageSize: CGSize) -> CGPoint {
        let x = (p.x - fit.minX) / scale
        let y = (p.y - fit.minY) / scale
        return CGPoint(x: min(max(0, x), imageSize.width), y: min(max(0, y), imageSize.height))
    }

    static func fitRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
