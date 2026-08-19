import Foundation

enum Fmt {
    static func time(_ t: Double) -> String {
        guard t.isFinite else { return "--:--" }
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%02d:%04.1f", m, s)
    }
}
