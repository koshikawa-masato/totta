import SwiftUI
import UniformTypeIdentifiers

/// fileExporter 用の PDF ラッパー(データはメモリ上のみ)
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// fileExporter 用の Markdown ラッパー(データはメモリ上のみ)
struct MarkdownFile: FileDocument {
    /// `.plainText` の既定拡張子は .txt なので、.md で保存するには Markdown の型を使う
    static let markdownType: UTType = UTType(filenameExtension: "md") ?? .plainText

    static var readableContentTypes: [UTType] { [markdownType, .plainText] }
    static var writableContentTypes: [UTType] { [markdownType] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 保存ダイアログ用の汎用ラッパー。
///
/// SwiftUI は同じビューに `.fileExporter` を 2 つ付けると片方しか機能しないため、
/// PDF と Markdown を 1 つの型にまとめて、保存口をひとつにする。
struct ExportableFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, MarkdownFile.markdownType, .plainText] }
    static var writableContentTypes: [UTType] { [.pdf, MarkdownFile.markdownType] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
