import SwiftUI
import TottaCore

struct SettingsView: View {
    @Bindable var model: ProjectModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("画面とカメラの向き") {
                    Toggle("横向きに固定(見開き向き)", isOn: $model.lockLandscape)
                    Text("見開きは横長なので、既定では端末を縦に持っていても画面ごと横向きで表示し、カメラも本来の横向きのまま取り込みます。プレビューと取り込み結果は常に同じ向きです。オフにすると端末の向きに追従します。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Section("ページ検出") {
                    LabeledSlider(title: "静止判定のしきい値", value: Binding(
                        get: { Double(model.analysisSettings.motionThreshold) },
                        set: { model.analysisSettings.motionThreshold = Float($0) }),
                        range: 0.5...15, step: 0.5, format: "%.1f",
                        help: "隣り合うフレームの平均輝度差がこれ未満なら「静止」とみなします。手ブレやノイズで検出されないときは上げてください")
                    LabeledSlider(title: "最短静止時間(秒)", value: $model.analysisSettings.minStillDuration,
                                  range: 0.3...3, step: 0.1, format: "%.1f",
                                  help: "この時間以上止まっていた区間だけをページとして採用します")
                    LabeledSlider(title: "動き判定の間隔(秒)", value: $model.analysisSettings.samplingInterval,
                                  range: 0.05...0.5, step: 0.05, format: "%.2f",
                                  help: "カメラ映像を何秒おきに見て動きを判定するか。小さいほど反応が速いですが負荷が増えます")
                    Toggle("Vision でページの枠を自動検出", isOn: $model.analysisSettings.detectPages)
                    LabeledSlider(title: "枠の最小サイズ(画面比)", value: Binding(
                        get: { Double(model.analysisSettings.minimumPageSize) },
                        set: { model.analysisSettings.minimumPageSize = Float($0) }),
                        range: 0.1...0.8, step: 0.05, format: "%.2f",
                        help: "これより小さい矩形は無視します")
                        .disabled(!model.analysisSettings.detectPages)
                }
                Section("重複ページ") {
                    LabeledSlider(title: "自動で捨てる差分(0で無効)", value: Binding(
                        get: { Double(model.analysisSettings.duplicateThreshold) },
                        set: { model.analysisSettings.duplicateThreshold = Float($0) }),
                        range: 0...10, step: 0.5, format: "%.1f",
                        help: "直前のページと切り出し画像を比べ、差がこれ未満ならほぼ同一として取り込みません")
                    LabeledSlider(title: "「酷似」警告を出す差分", value: Binding(
                        get: { Double(model.analysisSettings.similarWarningThreshold) },
                        set: { model.analysisSettings.similarWarningThreshold = Float($0) }),
                        range: 0...20, step: 0.5, format: "%.1f",
                        help: "差がこれ未満のページに警告マークを付けます。除外するかは一覧で判断できます")
                }
                Section("紙面の補正(書き出し時に適用)") {
                    Toggle("照明ムラ・影を取り除いて紙を白くする", isOn: $model.enhanceSettings.flattenLighting)
                    LabeledSlider(title: "黒点", value: $model.enhanceSettings.blackPoint,
                                  range: 0...0.6, step: 0.05, format: "%.2f",
                                  help: "これより暗い部分は黒に。上げると文字が締まりますが薄い文字が飛びます")
                        .disabled(!model.enhanceSettings.flattenLighting)
                    LabeledSlider(title: "白点", value: $model.enhanceSettings.whitePoint,
                                  range: 0.6...1.0, step: 0.02, format: "%.2f",
                                  help: "これより明るい部分は白に。下げると紙の地がより白くなります")
                        .disabled(!model.enhanceSettings.flattenLighting)
                    Toggle("指・手の映り込みを紙色で塗りつぶす", isOn: $model.enhanceSettings.removeFingers)
                    Text("Vision で手が検出されたときだけ、その位置の肌色領域を消します(手が写っていなければ何もしません)。クリーム色の紙は肌色に近く、誤検出するとページを消してしまうため既定はオフです。使う場合は「補正後」タブで結果を必ず確認してください。")
                        .font(.caption).foregroundStyle(.tertiary)
                    if model.enhanceSettings.removeFingers {
                        LabeledSlider(title: "消す面積の上限(ページ比)", value: $model.enhanceSettings.maxFingerCoverage,
                                      range: 0.02...0.25, step: 0.01, format: "%.2f",
                                      help: "これを超える面積を消そうとした場合は誤検出とみなし、何もしません")
                    }
                    Toggle("グレースケールで出力", isOn: $model.enhanceSettings.grayscale)
                    Text("本文スキャンに色は不要なので既定でオンです。ファイルが 2 割ほど小さくなります(実測: カラー 45.2MB → グレー 35.2MB / 14 ページ)。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Section("OCR(検索できる PDF)") {
                    Toggle("OCR して透明テキストを埋め込む", isOn: $model.ocrSettings.enabled)
                    Picker("認識言語", selection: Binding(
                        get: { model.ocrSettings.languages.joined(separator: ",") },
                        set: { model.ocrSettings.languages = $0.split(separator: ",").map(String.init) })) {
                        Text("日本語 + 英語").tag("ja-JP,en-US")
                        Text("英語 + 日本語").tag("en-US,ja-JP")
                        Text("日本語のみ").tag("ja-JP")
                        Text("英語のみ").tag("en-US")
                    }
                    .disabled(!model.ocrSettings.enabled)
                    Text("Vision によるオンデバイス OCR です。画像は端末の外に送られません。補正後の画像に対して実行します。オンにすると PDF 内で文字を検索・コピーできるほか、書き出し後に読み順で整形した Markdown (.md) も保存できます。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Section("PDF 書き出し") {
                    Toggle("見開きを左右 2 ページに分割", isOn: $model.exportSettings.splitSpread)
                    Toggle("右綴じ(右ページを先に)", isOn: $model.exportSettings.rightToLeft)
                        .disabled(!model.exportSettings.splitSpread)
                    Picker("ページ画像の長辺", selection: Binding(
                        get: { model.exportSettings.maxPageDimension ?? 0 },
                        set: { model.exportSettings.maxPageDimension = $0 == 0 ? nil : $0 })) {
                        Text("撮影したまま").tag(0)
                        Text("3000 px").tag(3000)
                        Text("2400 px").tag(2400)
                        Text("2000 px").tag(2000)
                        Text("1600 px").tag(1600)
                    }
                    Text("PDF に載せる画像を縮小します。OCR は縮小前のフル解像度で行うので認識精度は変わりません(14 ページ・グレー q0.75 の実測: 撮影したまま 29.4MB / 3000px 18.6MB / 2400px 12.6MB / 2000px 9.2MB / 1600px 6.2MB)。")
                        .font(.caption).foregroundStyle(.tertiary)
                    LabeledSlider(title: "JPEG 品質", value: $model.exportSettings.jpegQuality,
                                  range: 0.3...1.0, step: 0.05, format: "%.2f",
                                  help: "低いほどファイルが小さくなります。スキャン文書は輪郭が主なので、0.6〜0.75 でも可読性はほとんど落ちません(14 ページ・グレースケールで 0.85→35MB, 0.75→29MB, 0.60→18MB)")
                    Picker("用紙サイズ", selection: $model.exportSettings.paperSize) {
                        ForEach(PaperSize.allCases, id: \.self) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    if model.exportSettings.paperSize == .original {
                        Picker("ページサイズ計算の DPI", selection: $model.exportSettings.dpi) {
                            Text("100").tag(100.0)
                            Text("150").tag(150.0)
                            Text("200").tag(200.0)
                            Text("300").tag(300.0)
                        }
                    }
                }
                Section {
                    Text("設定はライブカメラの取り込みに即時反映されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 720)
        #endif
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let help {
                Text(help).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
