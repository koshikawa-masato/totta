import SwiftUI

@main
struct TottaApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(TottaAppDelegate.self) private var appDelegate
    #endif
    @State private var model = ProjectModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("ライブカメラを開始") { model.startLive() }
                    .keyboardShortcut("l")
                    .disabled(model.isBusy || model.isLive)
                Button("カメラを停止") { model.stopLive(clearPages: false) }
                    .disabled(!model.isLive)
                Divider()
                Button("PDF を書き出す…") { model.exportPDF() }
                    .keyboardShortcut("e")
                    .disabled(model.includedPages.isEmpty || model.isBusy)
                Button("セッションを破棄") { model.discardSession() }
                    .disabled(model.pages.isEmpty && !model.isLive)
            }
        }
        #endif
    }
}
