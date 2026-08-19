import SwiftUI
import TottaCore

/// 取り込みを始める前に、プレビューから取り出した静止画 1 枚の上で
/// 見開きの枠(四隅)とのど線を合わせる画面。確定すると基準枠として保存され、
/// 以降のページはこの枠で切り出される。
struct CalibrationView: View {
    @Bindable var model: ProjectModel
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

    private var quadBinding: Binding<Quad> {
        Binding(get: { model.calibration?.quad ?? Quad(rect: .zero) },
                set: { model.updateCalibrationQuad($0) })
    }
    private var spineBinding: Binding<Spine?> {
        Binding(get: { model.calibration?.spine },
                set: { model.updateCalibrationSpine($0) })
    }

    var body: some View {
        if let cal = model.calibration {
            VStack(spacing: 0) {
                header(cal)
                Divider()
                ZStack {
                    Color.black.opacity(0.06)
                    QuadEditor(image: cal.image, quad: quadBinding, spine: spineBinding)
                        .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ cal: ProjectModel.Calibration) -> some View {
        HStack(spacing: 10) {
            Text("枠を合わせる")
                .font(.headline)
            if isCompact {
                Menu {
                    Button { model.redetectCalibration() } label: { Label("自動検出", systemImage: "viewfinder") }
                    Button { model.setCalibrationFullFrame() } label: { Label("枠を全体に", systemImage: "rectangle") }
                    Button { model.toggleCalibrationSpine() } label: {
                        Label(cal.spine == nil ? "のど線を付ける" : "のど線を外す", systemImage: "rectangle.split.2x1")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Button { model.redetectCalibration() } label: { Label("自動検出", systemImage: "viewfinder") }
                Button { model.setCalibrationFullFrame() } label: { Label("全体", systemImage: "rectangle") }
                Toggle(isOn: Binding(get: { cal.spine != nil }, set: { _ in model.toggleCalibrationSpine() })) {
                    Label("のど線", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("見開きの左右ページを別々に台形補正します")
            }
            Spacer()
            Button("キャンセル") { model.cancelCalibration() }
            Button {
                model.confirmCalibration()
            } label: {
                Label("この枠で開始", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
