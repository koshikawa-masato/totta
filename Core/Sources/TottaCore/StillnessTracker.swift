import Foundation

/// 逐次入力されるフレーム指紋から「静止して十分時間が経った」瞬間を判定する。ライブカメラ用。
public struct StillnessTracker: Sendable {
    public enum Event: Sendable, Equatable {
        /// 動いている
        case moving
        /// 静止し始めてから minStillDuration までの進捗 (0-1)
        case settling(Double)
        /// 静止が確定した(このフレームを取り込むべき)。1つの静止区間につき1回だけ発火する
        case capture
        /// 取り込み済みのまま静止が続いている
        case held
    }

    public var motionThreshold: Float
    public var minStillDuration: Double

    private var lastFingerprint: Fingerprint?
    private var stillSince: Double?
    private var capturedThisRun = false

    public init(motionThreshold: Float, minStillDuration: Double) {
        self.motionThreshold = motionThreshold
        self.minStillDuration = minStillDuration
    }

    public mutating func reset() {
        lastFingerprint = nil
        stillSince = nil
        capturedThisRun = false
    }

    /// 現在の静止区間で既に取り込み済みなら、その区間で再度 capture が出ないようにする(手動取り込み後など)
    public mutating func markCaptured() {
        capturedThisRun = true
    }

    public mutating func feed(time: Double, fingerprint: Fingerprint) -> Event {
        defer { lastFingerprint = fingerprint }
        guard let last = lastFingerprint else {
            return .moving
        }
        let d = fingerprint.distance(to: last)
        if d >= motionThreshold {
            stillSince = nil
            capturedThisRun = false
            return .moving
        }
        if stillSince == nil { stillSince = time }
        let elapsed = time - stillSince!
        if elapsed >= minStillDuration {
            if capturedThisRun { return .held }
            capturedThisRun = true
            return .capture
        }
        return .settling(min(1, elapsed / minStillDuration))
    }
}
