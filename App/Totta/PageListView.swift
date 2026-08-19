import SwiftUI
import TottaCore

struct PageListView: View {
    @Bindable var model: ProjectModel
    /// iPhone など: 行タップで編集画面へプッシュする
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedPageID) {
                ForEach(model.pages) { page in
                    Group {
                        if compact {
                            NavigationLink(value: CompactRootView.Route.editor(page.id)) {
                                PageRow(model: model, page: page)
                            }
                        } else {
                            PageRow(model: model, page: page)
                        }
                    }
                    .tag(page.id)
                    .contextMenu {
                        Button(page.isIncluded ? "PDF から除外" : "PDF に含める") { model.toggleInclude(page.id) }
                        Button("枠を再検出") { model.redetect(page.id) }
                        Divider()
                        Button("削除", role: .destructive) { model.delete(page.id) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.delete(page.id) } label: { Label("削除", systemImage: "trash") }
                        Button { model.toggleInclude(page.id) } label: {
                            Label(page.isIncluded ? "除外" : "含める", systemImage: page.isIncluded ? "eye.slash" : "eye")
                        }
                    }
                }
            }
            #if os(macOS)
            .onDeleteCommand {
                if let id = model.selectedPageID { model.delete(id) }
            }
            #endif
            Divider()
            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(model.includedPages.count) / \(model.pages.count) ページ")
                    .font(.callout)
                Spacer()
                if model.pages.contains(where: { model.isSimilarToPrevious($0) && $0.isIncluded }) {
                    Button {
                        model.excludeSimilarPages()
                    } label: {
                        Label("酷似を除外", systemImage: "doc.on.doc.fill")
                            .font(.caption)
                    }
                    .help("前ページと酷似しているページをまとめて PDF から除外します")
                }
            }

            Button {
                model.exportPDF()
            } label: {
                Label("PDF にする (\(model.includedPages.count) ページ)", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.includedPages.isEmpty || model.isBusy)
            .help("含めるページを補正・OCR して PDF にします")

            if model.isLive, !model.pages.isEmpty, !compact {
                Button {
                    model.selectedPageID = nil
                } label: {
                    Label("カメラに戻る", systemImage: "video")
                        .font(.caption)
                }
                .disabled(model.selectedPageID == nil)
            }
        }
        .padding(10)
    }
}

struct PageRow: View {
    @Bindable var model: ProjectModel
    let page: CapturedPage

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb = model.thumbnails[page.id] {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 84, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(page.isIncluded ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if let n = model.outputNumber(of: page.id) {
                        Text("p.\(n)").font(.headline)
                    } else {
                        Text("除外").font(.headline).foregroundStyle(.secondary)
                    }
                    if page.source == .manual {
                        Image(systemName: "hand.tap").font(.caption2).foregroundStyle(.secondary)
                            .help("手動で追加")
                    }
                    if page.usedTemplate {
                        Image(systemName: "square.on.square").font(.caption2).foregroundStyle(.blue)
                            .help("基準枠を適用")
                    } else if page.confidence == nil {
                        Image(systemName: "rectangle.dashed").font(.caption2).foregroundStyle(.orange)
                            .help("枠が自動検出されず、フレーム全体を使っています")
                    }
                }
                Text(Fmt.time(page.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.isSimilarToPrevious(page) {
                    Label("前ページと酷似", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .help(String(format: "差分 %.1f", page.differenceFromPrevious ?? 0))
                }
            }
            Spacer(minLength: 0)
            Button {
                model.toggleInclude(page.id)
            } label: {
                Image(systemName: page.isIncluded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(page.isIncluded ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(page.isIncluded ? "PDF に含める(クリックで除外)" : "除外中(クリックで含める)")
        }
        .padding(.vertical, 2)
    }
}
