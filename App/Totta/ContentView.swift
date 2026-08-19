import SwiftUI
import UniformTypeIdentifiers
import TottaCore

struct ContentView: View {
    @Bindable var model: ProjectModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        // iPhone は横持ち(レギュラー幅)でも 1 カラム。iPad はサイズクラスに従う
        return UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            Group {
                #if os(iOS)
                if isCompact {
                    CompactRootView(model: model)
                } else {
                    splitView
                }
                #else
                splitView
                #endif
            }
            // 書き出し中の進捗は、どの画面を開いていても最前面に出す
            ExportOverlay(model: model)
        }
        .alert("エラー", isPresented: Binding(get: { model.errorMessage != nil },
                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("totta", isPresented: Binding(get: { model.infoMessage != nil },
                                             set: { if !$0 { model.infoMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.infoMessage ?? "")
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.isShowingPDFPreview, onDismiss: { model.previewDismissed() }) {
            PDFPreviewSheet(model: model)
        }
        #if os(iOS)
        .onAppear { OrientationLock.setLandscapeLocked(model.lockLandscape) }
        .onChange(of: model.lockLandscape) { _, locked in
            OrientationLock.setLandscapeLocked(locked)
        }
        #endif
    }

    private var splitView: some View {
        NavigationSplitView {
            PageListView(model: model, compact: false)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            DetailView(model: model)
        }
        .navigationTitle("totta")
        .toolbar { MainToolbar(model: model) }
    }
}

/// 共通ツールバー(カメラ開始/停止・設定・破棄・書き出し)
struct MainToolbar: ToolbarContent {
    @Bindable var model: ProjectModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isLive {
                Button {
                    model.stopLive(clearPages: false)
                } label: {
                    Label("カメラ停止", systemImage: "video.slash")
                }
                .help("ライブカメラを停止します(取り込んだページは残ります)")
            } else {
                Button {
                    model.startLive()
                } label: {
                    Label("ライブカメラ", systemImage: "video")
                }
                .help("カメラでページを取り込みます。映像は保存されません")
                .disabled(model.isBusy)
            }

            Button {
                model.showSettings = true
            } label: {
                Label("設定", systemImage: "slider.horizontal.3")
            }

            Button {
                model.discardSession()
            } label: {
                Label("破棄", systemImage: "trash")
            }
            .help("取り込んだページをすべて破棄してカメラを停止します")
            .disabled(model.pages.isEmpty && !model.isLive)

            Button {
                model.exportPDF()
            } label: {
                Label("PDF 書き出し", systemImage: "square.and.arrow.up")
            }
            .help("含めるページを PDF に書き出します。完了後、途中データは破棄されます")
            .disabled(model.includedPages.isEmpty || model.isBusy)
        }
    }
}

#if os(iOS)
/// iPhone(コンパクト幅)用: カメラ画面をルートに、ページ一覧 → 編集をプッシュで辿る
struct CompactRootView: View {
    @Bindable var model: ProjectModel
    @State private var path: [Route] = []
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscapePhone: Bool { verticalSizeClass == .compact }

    enum Route: Hashable {
        case pages
        case editor(UUID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                switch model.phase {
                case .empty:
                    EmptyStateView(model: model)
                case .ready, .exporting:
                    if model.isLive {
                        LiveCaptureView(model: model, onShowPages: { path = [.pages] })
                    } else {
                        ContentUnavailableView {
                            Label("カメラは停止中です", systemImage: "video.slash")
                        } description: {
                            Text("取り込んだページを確認・編集するか、PDF に書き出してください。")
                        } actions: {
                            Button("ライブカメラを再開") { model.startLive() }
                            Button("ページ一覧 (\(model.pages.count))") { path = [.pages] }
                        }
                    }
                }
            }
            .navigationTitle("totta")
            .navigationBarTitleDisplayMode(.inline)
            // カメラ表示中はナビバーを隠して映像を最大化(操作は OSD と下スワイプのバーに集約)
            .toolbar(model.isLive ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        path = [.pages]
                    } label: {
                        Label("ページ", systemImage: "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                    }
                    .badge(model.pages.count)
                    .disabled(model.pages.isEmpty)
                }
                MainToolbar(model: model)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .pages:
                    PageListView(model: model, compact: true)
                        .navigationTitle("ページ")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { model.showSettings = true } label: {
                                    Label("設定", systemImage: "slider.horizontal.3")
                                }
                            }
                        }
                case .editor(let id):
                    if let page = model.page(id) {
                        PageEditorView(model: model, page: page)
                            .navigationTitle(model.outputNumber(of: id).map { "p.\($0)" } ?? "除外")
                            .navigationBarTitleDisplayMode(.inline)
                                    } else {
                        ContentUnavailableView("ページが削除されました", systemImage: "trash")
                    }
                }
            }
        }
        .onChange(of: model.selectedPageID) { _, id in
            // ライブ画面のサムネイルタップなどで選択されたら編集画面へ
            if let id, path.last != .editor(id) {
                if path.isEmpty { path = [.pages, .editor(id)] } else { path.append(.editor(id)) }
            } else if id == nil, path.contains(where: { if case .editor = $0 { return true }; return false }) {
                path = []
            }
        }
        .onChange(of: path) { _, newPath in
            // 編集画面から戻ったら選択を解除
            if !newPath.contains(where: { if case .editor = $0 { return true }; return false }), model.selectedPageID != nil {
                model.selectedPageID = nil
            }
        }
    }
}

#else
enum CompactRootView { enum Route: Hashable { case pages, editor(UUID) } }
#endif

/// 書き出し中の進捗オーバーレイ
struct ExportOverlay: View {
    @Bindable var model: ProjectModel

    var body: some View {
        if let state = overlayState {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView(value: state.fraction) {
                        Text(state.message).font(.callout)
                    }
                    HStack {
                        Text("\(Int(state.fraction * 100)) %")
                        if let remaining = remainingText(state.fraction) {
                            Spacer()
                            Text(remaining)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Button("キャンセル", role: .cancel) { model.cancelExport() }
                }
                .frame(maxWidth: 320)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 12)
            }
            .transition(.opacity)
        }
    }

    private struct State {
        let fraction: Double
        let message: String
    }

    /// 経過時間から残りを見積もる
    private func remainingText(_ fraction: Double) -> String? {
        guard let start = model.exportStartedAt, fraction > 0.05, fraction < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed / fraction * (1 - fraction)
        guard remaining.isFinite, remaining > 1 else { return nil }
        if remaining < 60 { return "残り約 \(Int(remaining)) 秒" }
        return "残り約 \(Int(remaining / 60)) 分 \(Int(remaining.truncatingRemainder(dividingBy: 60))) 秒"
    }

    private var overlayState: State? {
        if case .exporting(let f, let message) = model.phase, !model.isShowingPDFPreview {
            return State(fraction: f, message: message)
        }
        return nil
    }
}

struct DetailView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .empty:
                EmptyStateView(model: model)
            case .ready, .exporting:
                readyContent
            }
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let page = model.selectedPage {
            PageEditorView(model: model, page: page)
        } else if model.isLive {
            LiveCaptureView(model: model)
        } else {
            ContentUnavailableView {
                Label("カメラは停止中です", systemImage: "video.slash")
            } description: {
                Text("左のリストからページを選んで確認・編集するか、PDF に書き出してください。続けて取り込むにはライブカメラを再開します。")
            } actions: {
                Button("ライブカメラを再開") { model.startLive() }
            }
        }
    }
}

struct EmptyStateView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "book.pages")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("totta")
                    .font(.largeTitle.bold())
                Text("固定したカメラの前で書籍の見開きを開いて止め、めくる。\n静止したページだけを自動で切り出し、PDF にします。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    model.startLive()
                } label: {
                    Label("ライブカメラで取り込む", systemImage: "video")
                        .frame(minWidth: 220)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}
