import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import TottaCore

/// 書き出した PDF を保存前に確認するシート
struct PDFPreviewSheet: View {
    @Bindable var model: ProjectModel
    /// PDF の解析結果は一度だけ作る。
    /// 計算プロパティにすると再描画のたびに 30MB の PDF を作り直し、PDFView が毎回リロードして固まる。
    @State private var document: PDFDocument?
    @State private var isLoading = true
    @State private var isConfirmingDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if let doc = document {
                    PDFKitView(document: doc)
                } else if isLoading {
                    ProgressView("PDF を読み込み中…")
                } else {
                    ContentUnavailableView("PDF を読み込めません", systemImage: "doc.questionmark")
                }
            }
            .task {
                guard document == nil, let data = model.exportedDocument?.data else {
                    isLoading = false
                    return
                }
                let doc = await Task.detached(priority: .userInitiated) { PDFDocument(data: data) }.value
                document = doc
                isLoading = false
            }
            .safeAreaInset(edge: .bottom) {
                if model.savedPDFName != nil || model.savedMarkdownName != nil {
                    VStack(spacing: 3) {
                        if let pdf = model.savedPDFName {
                            Label("PDF を \(pdf) に保存しました", systemImage: "checkmark.circle.fill")
                        }
                        if let md = model.savedMarkdownName {
                            Label("テキストを \(md) に保存しました", systemImage: "checkmark.circle.fill")
                        }
                        if model.savedPDFName != nil {
                            Text("閉じると取り込んだページは破棄されます")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.savedPDFName != nil {
                        Button("完了") { model.isShowingPDFPreview = false }
                    } else {
                        Button("破棄", role: .destructive) { isConfirmingDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.requestSavePDF()
                    } label: {
                        Label(model.savedPDFName == nil ? "PDF を保存" : "保存済み",
                              systemImage: model.savedPDFName == nil ? "square.and.arrow.down" : "checkmark.circle")
                    }
                    .disabled(model.exportedDocument == nil)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.requestSaveMarkdown()
                    } label: {
                        Label("テキスト (.md)", systemImage: "doc.text")
                    }
                    .disabled(model.exportedMarkdown == nil)
                    .help(model.exportedMarkdown == nil
                          ? "OCR がオフか、テキストを認識できませんでした"
                          : "OCR したテキストを Markdown で保存します")
                }
            }
        }
        .confirmationDialog("取り込んだページをすべて破棄して最初の画面に戻ります。",
                            isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("すべて破棄", role: .destructive) { model.discardExportedPDF() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この PDF と、取り込んだ \(model.pages.count) ページは復元できません。")
        }
        // 保存ダイアログはこのシートの上に出す。
        // `.fileExporter` を 2 つ重ねると片方しか動かないので、PDF と .md で 1 つを使い回す。
        .fileExporter(isPresented: $model.isShowingExporter,
                      document: model.pendingFile,
                      contentTypes: [model.pendingFileType],
                      defaultFilename: model.pendingFileName) { result in
            model.exportFinished(result)
        } onCancellation: {
            model.exportCancelled()
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 560)
        #endif
    }

    private var title: String {
        guard let doc = document else { return "PDF" }
        let bytes = model.exportedDocument?.data.count ?? 0
        let mb = Double(bytes) / 1_048_576
        var t = String(format: "%d ページ・%.1f MB", doc.pageCount, mb)
        if let md = model.exportedMarkdown {
            t += String(format: " ・テキスト %d 字", md.text.count)
        }
        return t
    }
}

#if os(macOS)
import AppKit

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = document
        return v
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#else
import UIKit

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.usePageViewController(false)
        v.document = document
        return v
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif
