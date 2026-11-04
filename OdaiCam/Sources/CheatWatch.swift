import CoreVideo
import Foundation
import Vision

/// 内側のカメラで当てる人の顔を見て、画面から目を離した（顔を上げて本人を直接見た）らカンニングとする。
///
/// 目線は取れないので、顔の向きで見る。ラウンドの最初の 1 秒の向きを基準にして、
/// 顔が見えなくなった、または基準から大きく上下左右に向いた状態が続いたら知らせる。
/// 画面の下の ○・パスを見るくらいの動きでは鳴らないよう、幅と続く時間に余裕を持たせる
final class CheatWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cheat", qos: .utility)
    private let lock = NSLock()
    private var active = false
    private var busy = false
    private var lastCheck: TimeInterval = 0
    private var baseline: (pitch: Double, yaw: Double)?
    private var calibration: [(pitch: Double, yaw: Double)] = []
    private var badSince: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private let request: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    /// カンニングした（main で呼ぶ）
    var onCheat: (@MainActor () -> Void)?

    /// 顔が基準からこれ以上向いたら目を離したとみなす（ラジアン、約 23°）
    static let turnLimit = 0.4
    /// この時間続いたらカンニング
    static let holdSeconds = 0.6

    func setActive(_ on: Bool) {
        lock.withLock {
            active = on
            baseline = nil
            calibration = []
            badSince = nil
            cooldownUntil = 0
        }
    }

    /// カメラのキューから呼ぶ。10 回/秒だけ見る
    func process(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let go: Bool = lock.withLock {
            guard active, !busy, now - lastCheck >= 0.1 else { return false }
            busy = true
            lastCheck = now
            return true
        }
        guard go else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            try? VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
            let face = (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
            let pose = face.map { (pitch: $0.pitch?.doubleValue ?? 0, yaw: $0.yaw?.doubleValue ?? 0) }
            let cheat: Bool = lock.withLock { judge(pose, now: now) }
            if cheat { Task { @MainActor [onCheat] in onCheat?() } }
        }
    }

    private func judge(_ pose: (pitch: Double, yaw: Double)?, now: TimeInterval) -> Bool {
        guard active else { return false }
        guard let baseline else {
            // 最初の 1 秒（10 回）で基準を決める
            if let pose { calibration.append(pose) }
            if calibration.count >= 10 {
                let n = Double(calibration.count)
                self.baseline = (calibration.map(\.pitch).reduce(0, +) / n, calibration.map(\.yaw).reduce(0, +) / n)
            }
            return false
        }
        let bad: Bool
        if let pose {
            bad = abs(pose.pitch - baseline.pitch) > Self.turnLimit || abs(pose.yaw - baseline.yaw) > Self.turnLimit
        } else {
            bad = true
        }
        guard bad, now >= cooldownUntil else {
            if !bad { badSince = nil }
            return false
        }
        let since = badSince ?? now
        badSince = since
        guard now - since >= Self.holdSeconds else { return false }
        badSince = nil
        cooldownUntil = now + 2.5
        return true
    }
}
