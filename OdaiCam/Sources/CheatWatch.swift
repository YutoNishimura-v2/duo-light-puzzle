import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// 内側のカメラで当てる人の顔を見て、顔を上げて本人を直接見たらカンニングとする。
///
/// 目線は取れないので、顔の向きで見る。見るのは「上を向いた」ときだけ。
/// 顔が見えなくなった・横を向いた・下の ○・パスを見た、では鳴らさない。
/// 上向きは 2 つの手がかりで見る：
/// - 鼻の位置：顔を上げると、鼻先が目と口の間で目の側に寄って見える（向きの符号に頼らない）
/// - pitch（Vision の顔の上下の角度）：基準からの変わり幅だけ使う（符号は端末で確かめていないので使わない）
/// 鼻が上に寄り、それが 0.4 秒続いたら 1 回。顔を下ろすまで次は数えない（1 回見上げて 1 回だけ）
final class CheatWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cheat", qos: .utility)
    private let lock = NSLock()
    private var active = false
    private var busy = false
    private var lastCheck: TimeInterval = 0
    /// 画面を見ているときの顔（鼻の位置の比と pitch）
    private var baseline: Pose?
    private var calibration: [Pose] = []
    private var upSince: TimeInterval?
    /// 最後に顔が見えた時刻
    private var lastSeen: TimeInterval = 0
    /// 一度鳴らしたら、顔を下ろすまで鳴らさない
    private var armed = true
    private var cooldownUntil: TimeInterval = 0
    private let request: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        return r
    }()

    struct Pose {
        /// 鼻が口から目へどこまで寄っているか（0 = 口の高さ、1 = 目の高さ）。上を向くと大きくなる
        var nose: Double
        /// 顔の上下の角度（ラジアン）。取れなければ nil
        var pitch: Double?
    }

    /// カンニングした（main で呼ぶ）
    var onCheat: (@MainActor () -> Void)?

    /// 鼻の比が基準からこれだけ上がったら上を向いたとみなす（およそ 15° ぶん）
    static let noseLimit = 0.10
    /// pitch も大きく動いているときは、鼻の比が少し上がっただけでも上向きとみなす
    static let noseLimitWithPitch = 0.05
    static let pitchLimit = 0.30
    /// この時間続いたらカンニング
    static let holdSeconds = 0.4
    /// 1 回鳴らしたら、この間は鳴らさない
    static let cooldownSeconds = 3.0
    /// 顔がこれ以上見えなければ、上向きの続きを数え直す
    static let lostReset = 0.5

    func setActive(_ on: Bool) {
        lock.withLock {
            active = on
            baseline = nil
            calibration = []
            upSince = nil
            lastSeen = 0
            armed = true
            cooldownUntil = 0
        }
    }

    /// カメラのキューから呼ぶ。10 回/秒だけ見る。
    /// 内側のカメラのフレームは出力の接続で水平に回してから届くので、向きは .up で渡す
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
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let face = (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
            let pose = face.flatMap { Self.pose(of: $0, imageSize: size) }
            let cheat: Bool = lock.withLock { judge(pose, now: now) }
            if cheat { Task { @MainActor [onCheat] in onCheat?() } }
        }
    }

    /// 目・鼻・口の位置から、鼻が口から目へどこまで寄っているかを出す。
    /// 口→目の向きに沿って測るので、画像が回っていても値は変わらない
    static func pose(of face: VNFaceObservation, imageSize: CGSize) -> Pose? {
        guard let lm = face.landmarks,
              let leftEye = lm.leftEye, let rightEye = lm.rightEye,
              let nose = lm.nose, let lips = lm.outerLips else { return nil }
        let eyes = center(leftEye.pointsInImage(imageSize: imageSize) + rightEye.pointsInImage(imageSize: imageSize))
        let noseC = center(nose.pointsInImage(imageSize: imageSize))
        let mouth = center(lips.pointsInImage(imageSize: imageSize))
        guard let eyes, let noseC, let mouth else { return nil }
        let ax = eyes.x - mouth.x, ay = eyes.y - mouth.y
        let len2 = ax * ax + ay * ay
        guard len2 > 1 else { return nil }
        let t = ((noseC.x - mouth.x) * ax + (noseC.y - mouth.y) * ay) / len2
        return Pose(nose: Double(t), pitch: face.pitch?.doubleValue)
    }

    private static func center(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s[s.count / 2]
    }

    private func judge(_ pose: Pose?, now: TimeInterval) -> Bool {
        guard active else { return false }
        // 顔が見えないだけでは減点しない。しばらく見えなければ数え直す
        guard let pose else {
            if now - lastSeen > Self.lostReset { upSince = nil }
            return false
        }
        lastSeen = now
        guard var base = baseline else {
            // 顔が見えた最初の 10 回（約 1 秒）の中央値を基準にする
            calibration.append(pose)
            if calibration.count >= 10 {
                let pitches = calibration.compactMap(\.pitch)
                baseline = Pose(nose: Self.median(calibration.map(\.nose)),
                                pitch: pitches.isEmpty ? nil : Self.median(pitches))
            }
            return false
        }
        let rise = pose.nose - base.nose
        let turn: Double = {
            guard let p = pose.pitch, let b = base.pitch else { return 0 }
            return abs(p - b)
        }()
        let up = rise > Self.noseLimit || (rise > Self.noseLimitWithPitch && turn > Self.pitchLimit)
        guard up else {
            upSince = nil
            armed = true
            // 画面を見ている顔に少しずつ合わせる。下を向いたほうへは早めに寄せる
            // （基準を取ったときに上を向いていても、すぐ直る）
            let k = rise < 0 ? 0.2 : 0.03
            base.nose += (pose.nose - base.nose) * k
            if let p = pose.pitch, let b = base.pitch { base.pitch = b + (p - b) * k }
            baseline = base
            return false
        }
        guard armed, now >= cooldownUntil else { return false }
        let since = upSince ?? now
        upSince = since
        guard now - since >= Self.holdSeconds else { return false }
        upSince = nil
        armed = false
        cooldownUntil = now + Self.cooldownSeconds
        return true
    }
}
