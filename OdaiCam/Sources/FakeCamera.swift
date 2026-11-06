@preconcurrency import AVFoundation
import CoreImage
import UIKit
import VideoToolbox
import Vision

/// 試験用の偽カメラ（起動引数 -fakeCamera YES）。シミュレータにはカメラがないので、動画を流して本物と同じ道を通す。
/// 同梱の fake-camera.mp4（CI でだけ入れる）を繰り返し流す。なければ動く人形をその場で描く。
/// 時刻は本物のカメラと同じ時計（ホストの時計）で付け直す。録画の頭からの秒数がずれないように
///
/// デモ（起動引数 -demo YES。偽カメラも入る）：動画は使わず、演じる人を毎コマ描く。
/// 姿勢は時刻だけで決まるので、しばりの処理は同じ時刻の骨組み・型抜きを DemoActor から受け取れる
/// （シミュレータでは Vision が人を見つけないため）。内側のカメラの代わりに、当てる人の顔も描いて流す
final class FakeCamera: @unchecked Sendable {
    static let isDemo = UserDefaults.standard.bool(forKey: "demo")
    static let isOn = ProcessInfo.processInfo.arguments.contains("-fakeCamera") || isDemo

    /// 1 コマ届けるたびに呼ぶ（カメラのキューで呼ぶ）
    var deliver: ((CMSampleBuffer) -> Void)?
    /// デモだけ：当てる人の顔のコマを届ける（カメラのキューで呼ぶ）
    var deliverFront: ((CMSampleBuffer) -> Void)?
    /// プレビューを描く層（main でだけ触る）
    weak var previewLayer: CALayer?

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var faceTimer: DispatchSourceTimer?
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pool: CVPixelBufferPool?
    private var actorPool: CVPixelBufferPool?
    private var facePool: CVPixelBufferPool?
    /// デモの部屋（一度だけ描いて使い回す）
    private var room: CGImage?
    private var count = 0
    /// プレビューのコマを main に渡して、まだ受け取られていない（previewLock で守る）
    private let previewLock = NSLock()
    private var previewInFlight = false
    /// いま流しているコマの大きさ（録画の設定に使う）
    private(set) var size = FakeCamera.isDemo ? DemoActor.size : CGSize(width: 540, height: 960)

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 録画の設定（本物ではカメラの出力が勧める値を使う）。カメラのキューで呼ぶ
    var videoSettings: [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
    }

    /// デモの顔の録画の設定
    var frontVideoSettings: [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(DemoFace.size.width), AVVideoHeightKey: Int(DemoFace.size.height)]
    }

    /// カメラのキューで呼ぶ
    func start() {
        guard timer == nil else { return }
        if Self.isDemo {
            // 顔は 15 コマ/秒
            let f = DispatchSource.makeTimerSource(queue: queue)
            f.schedule(deadline: .now(), repeating: 1.0 / 15)
            f.setEventHandler { [weak self] in self?.faceTick() }
            f.resume()
            faceTimer = f
        } else if let url = Bundle.main.url(forResource: "fake-camera", withExtension: "mp4") {
            let asset = AVURLAsset(url: url)
            Task { [self] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
                queue.async { [self] in
                    self.asset = asset
                    self.track = track
                }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        let hasMovie = Bundle.main.url(forResource: "fake-camera", withExtension: "mp4") != nil
        let source = Self.isDemo ? "デモ" : (hasMovie ? "動画" : "描いた人形")
        CrashLog.mark("偽カメラ開始（\(source)）")
    }

    /// カメラのキューで呼ぶ
    func stop() {
        timer?.cancel()
        timer = nil
        faceTimer?.cancel()
        faceTimer = nil
        // 止めている間は、描き置きの部屋と画素の箱を手放す（次に動かすとき作り直す）
        room = nil
        pool = nil
        actorPool = nil
        facePool = nil
    }

    private static func sample(_ pb: CVPixelBuffer, at time: CMTime, fps: Int32) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    private func tick() {
        // コマごとの一時的な絵を、このコマの終わりで手放す
        autoreleasepool { tickBody() }
    }

    private func tickBody() {
        // 描く前に時刻を決める（デモの骨組みは、このコマの時刻で引き直す）
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let frame = Self.isDemo ? drawActor(t: now.seconds) : (readFrame() ?? drawFrame())
        guard let pb = frame else { return }
        size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        guard let sample = Self.sample(pb, at: now, fps: 30) else { return }
        deliver?(sample)
        // プレビューは 10 コマ/秒で足りる
        count += 1
        // main がまだ前のコマを受け取っていなければ渡さない（main が詰まったとき、画素の箱を抱えた仕事が積み上がらないように）
        if count % 3 == 0, previewLock.withLock({ () -> Bool in
            if previewInFlight { return false }
            previewInFlight = true
            return true
        }) {
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
            if let cg {
                DispatchQueue.main.async { [self] in
                    previewLayer?.contents = cg
                    previewLock.withLock { previewInFlight = false }
                }
            } else {
                previewLock.withLock { previewInFlight = false }
            }
        }
    }

    /// 同梱の動画から 1 コマ。終わったら頭から読み直す
    private func readFrame() -> CVPixelBuffer? {
        guard let asset, let track else { return nil }
        for _ in 0..<2 {
            if output == nil {
                guard let r = try? AVAssetReader(asset: asset) else { return nil }
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ])
                guard r.canAdd(o) else { return nil }
                r.add(o)
                guard r.startReading() else { return nil }
                reader = r
                output = o
            }
            if let sb = output?.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) { return pb }
            reader?.cancelReading()
            reader = nil
            output = nil
        }
        return nil
    }

    /// 動画がないときの代わり：腕と脚を振る人形
    private func drawFrame() -> CVPixelBuffer? {
        let w = 540, h = 960
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // 壁と床
        ctx.setFillColor(UIColor(red: 0.78, green: 0.74, blue: 0.68, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor(red: 0.45, green: 0.36, blue: 0.28, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 200))
        // 人形（CGContext は左下が原点）
        let t = ProcessInfo.processInfo.systemUptime
        let swing = sin(t * 3)
        let cx = CGFloat(w) / 2 + CGFloat(sin(t * 0.7)) * 60
        let hip = CGPoint(x: cx, y: 420), neck = CGPoint(x: cx, y: 680)
        func limb(_ from: CGPoint, _ angle: Double, _ length: CGFloat) -> CGPoint {
            CGPoint(x: from.x + CGFloat(sin(angle)) * length, y: from.y - CGFloat(cos(angle)) * length)
        }
        ctx.setLineCap(.round)
        ctx.setStrokeColor(UIColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1).cgColor)
        ctx.setLineWidth(56)
        ctx.move(to: hip); ctx.addLine(to: neck); ctx.strokePath()
        ctx.setLineWidth(36)
        for (from, angle, length) in [(hip, 0.35 * swing, 220.0), (hip, -0.35 * swing, 220.0),
                                      (neck, 2.2 + 0.8 * swing, 200.0), (neck, -2.2 + 0.8 * swing, 200.0)] {
            ctx.move(to: from); ctx.addLine(to: limb(from, angle, CGFloat(length))); ctx.strokePath()
        }
        ctx.setFillColor(UIColor(red: 0.93, green: 0.76, blue: 0.62, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 50, y: 700, width: 100, height: 115))
        return pb
    }

    // MARK: デモ

    /// デモ：部屋で演じる人の 1 コマ（時刻 t の姿勢）
    private func drawActor(t: TimeInterval) -> CVPixelBuffer? {
        let size = DemoActor.size
        guard let pb = Self.makeBuffer(&actorPool, width: Int(size.width), height: Int(size.height)) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = Self.context(pb) else { return nil }
        if room == nil { room = DemoActor.room() }
        if let room {
            // 部屋は画素の箱と同じ並び（BGRA）で描いてあるので、混ぜずにそのまま写す（毎コマの変換をしない）
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(room, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        DemoActor.draw(DemoActor.body(at: t), in: ctx, mask: false)
        DemoActor.vignette(ctx)
        return pb
    }

    /// デモ：当てる人の顔を、内側のカメラと同じ道に流す
    private func faceTick() {
        autoreleasepool { faceTickBody() }
    }

    private func faceTickBody() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let size = DemoFace.size
        guard let pb = Self.makeBuffer(&facePool, width: Int(size.width), height: Int(size.height)) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = Self.context(pb) { DemoFace.draw(at: now.seconds, in: ctx) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard let sample = Self.sample(pb, at: now, fps: 15) else { return }
        deliverFront?(sample)
    }

    private static func makeBuffer(_ pool: inout CVPixelBufferPool?, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// 鍵をかけた画素の箱に描く（左下が原点）
    private static func context(_ pb: CVPixelBuffer) -> CGContext? {
        CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

private func gradient(_ colors: [CGColor]) -> CGGradient? {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)
}

/// 0〜1 の決まった乱数（同じ i なら同じ値）
private func noise(_ i: Int) -> Double {
    let x = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
    return x - floor(x)
}

private func smooth(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}

/// デモの演じる人。時刻だけで姿勢が決まる（同じ時刻なら、映像・骨組み・型抜きがぴったり重なる）。
/// 座標は 720x1280 の画素で、左下が原点（Vision と CGContext に合わせる）
enum DemoActor {
    static let size = CGSize(width: 720, height: 1280)
    /// 靴の底が着く高さ
    static let floorY: CGFloat = 330
    /// 1 つの動きの長さ（秒）と、次の動きへのつなぎ
    static let moveLength = 3.6
    static let blendLength = 0.5
    static let moveCount = 8

    /// 関節の角度。配列は [本人の右（画面の左）, 本人の左（画面の右）]。
    /// 手足の角度は真下が 0、外へ開くほど大きく、π で真上
    struct Pose {
        var x = 0.0, lean = 0.0, tilt = 0.0, lift = 0.0
        var upper = [0.15, 0.15], bend = [0.1, 0.1]
        var thigh = [0.08, 0.08], knee = [-0.05, -0.05]

        static func mix(_ a: Pose, _ b: Pose, _ k: Double) -> Pose {
            func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
            func m2(_ x: [Double], _ y: [Double]) -> [Double] { [m(x[0], y[0]), m(x[1], y[1])] }
            var p = Pose()
            p.x = m(a.x, b.x); p.lean = m(a.lean, b.lean); p.tilt = m(a.tilt, b.tilt); p.lift = m(a.lift, b.lift)
            p.upper = m2(a.upper, b.upper); p.bend = m2(a.bend, b.bend)
            p.thigh = m2(a.thigh, b.thigh); p.knee = m2(a.knee, b.knee)
            return p
        }
    }

    /// 関節の位置（画素）。配列は Pose と同じ並び
    struct Body {
        var root = CGPoint.zero, neck = CGPoint.zero, head = CGPoint.zero, nose = CGPoint.zero
        /// 頭の傾き（時計回りが正、ラジアン）
        var headAngle = 0.0
        var lift: CGFloat = 0
        var shoulder: [CGPoint] = [], elbow: [CGPoint] = [], wrist: [CGPoint] = []
        var hip: [CGPoint] = [], knee: [CGPoint] = [], ankle: [CGPoint] = []
    }

    /// 動きの番号と、その動きの頭からの秒
    private static func move(_ i: Int, _ p: Double) -> Pose {
        var o = Pose()
        switch i {
        case 0:
            // ゴリラ：がに股で胸をたたく
            o.thigh = [0.6, 0.6]; o.knee = [-0.95, -0.95]
            o.lean = 0.06 * sin(p * 2)
            for s in 0..<2 {
                let beat = max(0, sin(p * 9 + Double(s) * .pi))
                o.upper[s] = 0.95 + 0.3 * beat
                o.bend[s] = -2.9 + 0.7 * beat
            }
            o.lift = 8 * abs(sin(p * 4.5))
        case 1:
            // 鳥：羽ばたいて片足立ち
            let flap = sin(p * 7)
            o.upper = [1.35 + 0.75 * flap, 1.35 + 0.75 * flap]
            o.bend = [0.3 * sin(p * 7 - 1), 0.3 * sin(p * 7 - 1)]
            o.thigh = [0.9, 0.06]; o.knee = [-1.9, 0]
            o.lean = 0.1 * sin(p * 1.5)
            o.tilt = -0.1 * sin(p * 1.5)
            o.lift = 12 * abs(sin(p * 3.5))
        case 2:
            // ゾウ：両腕を鼻にして揺らす
            for s in 0..<2 {
                let sign = s == 0 ? -1.0 : 1.0
                o.upper[s] = -0.3 + sign * 0.4 * sin(p * 2.6)
                o.bend[s] = sign * 0.25 * sin(p * 2.6 - 0.8)
            }
            o.lean = 0.12 * sin(p * 2.6)
            o.tilt = 0.15 * sin(p * 2.6)
            o.thigh = [0.2, 0.2]; o.knee = [-0.25, -0.25]
        case 3:
            // カンガルー：前足を胸に、跳ねる
            let s = sin(p * 7.5)
            let crouch = max(0, -s)
            o.lift = 110 * max(0, s)
            o.thigh = [0.25 + 0.35 * crouch, 0.25 + 0.35 * crouch]
            o.knee = [-0.2 - 0.9 * crouch, -0.2 - 0.9 * crouch]
            o.upper = [0.5, 0.5]; o.bend = [-2.3, -2.3]
            o.tilt = 0.08 * s
        case 4:
            // クロール：腕を交互に回す
            // 角度は -π〜π にたたむ（つなぎで腕が何周も回らないように）
            o.upper = [remainder(p * 4.2, 2 * .pi), remainder(p * 4.2 + .pi, 2 * .pi)]
            o.bend = [0.15, 0.15]
            o.lean = 0.12 * sin(p * 2.1)
            o.tilt = -0.25 * sin(p * 2.1)
            o.thigh = [0.12 + 0.1 * sin(p * 9), 0.12 + 0.1 * sin(p * 9 + .pi)]
            o.knee = [-0.2, -0.2]
        case 5:
            // うさぎ：手を耳にして小さく跳ねる
            let wiggle = 0.25 * sin(p * 10)
            o.upper = [2.4, 2.4]; o.bend = [1.05 + wiggle, 1.05 - wiggle]
            o.lift = 40 * max(0, sin(p * 9))
            o.thigh = [0.15, 0.15]; o.knee = [-0.3, -0.3]
        case 6:
            // ペンギン：腕を張って左右に揺れて歩く
            let flap = 0.2 * max(0, sin(p * 12))
            o.upper = [0.35 + flap, 0.35 + flap]; o.bend = [0.45, 0.45]
            o.lean = 0.16 * sin(p * 4)
            o.tilt = -0.08 * sin(p * 4)
            o.x = 45 * sin(p * 2)
            o.thigh = [0.04, 0.04]
            o.knee = [-0.35 * max(0, sin(p * 4)), -0.35 * max(0, -sin(p * 4))]
        default:
            // エアギター：のけぞって頭を振る
            o.upper = [0.5, 0.75]
            o.bend = [-2.0 + 0.45 * sin(p * 14), 0.55]
            o.lean = -0.12 + 0.04 * sin(p * 3.5)
            o.tilt = 0.25 * sin(p * 7)
            o.thigh = [0.35, 0.35]; o.knee = [-0.2, -0.2]
        }
        return o
    }

    static func pose(at t: Double) -> Pose {
        let k = Int(floor(t / moveLength))
        let local = t - Double(k) * moveLength
        func index(_ k: Int) -> Int { ((k % moveCount) + moveCount) % moveCount }
        let current = move(index(k), local)
        guard local < blendLength else { return current }
        // 前の動きから滑らかにつなぐ
        let previous = move(index(k - 1), local + moveLength)
        return Pose.mix(previous, current, smooth(local / blendLength))
    }

    private static func off(_ p: CGPoint, _ d: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: p.x + d.x * k, y: p.y + d.y * k)
    }

    /// 手足の向き。s は画面の左（-1）か右（+1）
    private static func limb(_ a: Double, _ s: CGFloat) -> CGPoint {
        CGPoint(x: s * CGFloat(sin(a)), y: -CGFloat(cos(a)))
    }

    static func body(at t: Double) -> Body {
        let p = pose(at: t)
        let up = CGPoint(x: sin(p.lean), y: cos(p.lean))
        let side = CGPoint(x: cos(p.lean), y: -sin(p.lean))
        let headDir = CGPoint(x: sin(p.lean + p.tilt), y: cos(p.lean + p.tilt))
        var b = Body()
        b.neck = off(.zero, up, 240)
        b.head = off(b.neck, headDir, 80)
        b.nose = off(b.head, headDir, -8)
        b.headAngle = p.lean + p.tilt
        b.lift = CGFloat(p.lift)
        for i in 0..<2 {
            let s: CGFloat = i == 0 ? -1 : 1
            let shoulder = off(off(b.neck, side, 66 * s), up, -14)
            let elbow = off(shoulder, limb(p.upper[i], s), 120)
            let wrist = off(elbow, limb(p.upper[i] + p.bend[i], s), 112)
            let hip = off(.zero, side, 38 * s)
            let knee = off(hip, limb(p.thigh[i], s), 165)
            let ankle = off(knee, limb(p.thigh[i] + p.knee[i], s), 160)
            b.shoulder.append(shoulder); b.elbow.append(elbow); b.wrist.append(wrist)
            b.hip.append(hip); b.knee.append(knee); b.ankle.append(ankle)
        }
        // 低いほうの足を床に着け、部屋の中をゆっくり左右に動く
        let dx = size.width / 2 + CGFloat(60 * sin(t * 0.37) + p.x)
        let dy = floorY + b.lift - min(b.ankle[0].y, b.ankle[1].y)
        func shift(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + dx, y: q.y + dy) }
        b.root = shift(b.root); b.neck = shift(b.neck); b.head = shift(b.head); b.nose = shift(b.nose)
        b.shoulder = b.shoulder.map(shift); b.elbow = b.elbow.map(shift); b.wrist = b.wrist.map(shift)
        b.hip = b.hip.map(shift); b.knee = b.knee.map(shift); b.ankle = b.ankle.map(shift)
        return b
    }

    /// Vision と同じ名前の関節（0〜1、左下が原点）。Vision の左右は本人から見た左右
    static func joints(at t: Double) -> [VNHumanBodyPoseObservation.JointName: CGPoint] {
        let b = body(at: t)
        func n(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
        return [
            .nose: n(b.nose), .neck: n(b.neck), .root: n(b.root),
            .rightShoulder: n(b.shoulder[0]), .rightElbow: n(b.elbow[0]), .rightWrist: n(b.wrist[0]),
            .leftShoulder: n(b.shoulder[1]), .leftElbow: n(b.elbow[1]), .leftWrist: n(b.wrist[1]),
            .rightHip: n(b.hip[0]), .rightKnee: n(b.knee[0]), .rightAnkle: n(b.ankle[0]),
            .leftHip: n(b.hip[1]), .leftKnee: n(b.knee[1]), .leftAnkle: n(b.ankle[1]),
        ]
    }

    /// 人の形の型抜き（白が人）を、渡された 8 ビット 1 色（kCVPixelFormatType_OneComponent8）の画素の箱に描く。
    /// 箱はしばりの処理が使い回す（毎コマ新しい CGImage を作ると、Core Image が絵を抱え込んでメモリが増え続ける）。
    /// 描けたら true
    static func mask(at t: Double, into pb: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        draw(body(at: t), in: ctx, mask: true)
        ctx.flush()
        return true
    }

    /// 人を描く。mask のときは全部白で、顔や影は描かない
    static func draw(_ b: Body, in ctx: CGContext, mask: Bool) {
        let white = CGColor(gray: 1, alpha: 1)
        func c(_ color: CGColor) -> CGColor { mask ? white : color }
        let skin = c(rgb(0.91, 0.72, 0.57)), shirt = c(rgb(0.93, 0.43, 0.33)), pants = c(rgb(0.2, 0.27, 0.42))
        let shoe = c(rgb(0.14, 0.14, 0.17)), hair = c(rgb(0.17, 0.11, 0.08))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 床の影（跳ぶと小さく薄くなる）
        if !mask {
            let k = max(0.4, 1 - b.lift / 250)
            let cx = (b.ankle[0].x + b.ankle[1].x) / 2
            ctx.setFillColor(rgb(0.15, 0.1, 0.06, 0.28 * k))
            ctx.fillEllipse(in: CGRect(x: cx - 130 * k, y: floorY - 42, width: 260 * k, height: 44))
        }

        // 脚と靴
        for i in 0..<2 {
            let s: CGFloat = i == 0 ? -1 : 1
            ctx.setStrokeColor(pants)
            ctx.setLineWidth(54)
            ctx.move(to: b.hip[i]); ctx.addLine(to: b.knee[i]); ctx.addLine(to: b.ankle[i])
            ctx.strokePath()
            ctx.setFillColor(shoe)
            ctx.fillEllipse(in: CGRect(x: b.ankle[i].x - 30 + s * 12, y: b.ankle[i].y - 32, width: 64, height: 32))
            if !mask {
                ctx.setFillColor(rgb(0.92, 0.92, 0.9))
                ctx.fill(CGRect(x: b.ankle[i].x - 26 + s * 12, y: b.ankle[i].y - 33, width: 56, height: 6))
            }
        }

        // 胴（シャツ）。窓の側（左）を明るく
        let torso = CGMutablePath()
        torso.addLines(between: [b.shoulder[0], b.shoulder[1],
                                 CGPoint(x: b.hip[1].x + 16, y: b.hip[1].y), CGPoint(x: b.hip[0].x - 16, y: b.hip[0].y)])
        torso.closeSubpath()
        ctx.setFillColor(shirt)
        ctx.setStrokeColor(shirt)
        ctx.setLineWidth(44)
        ctx.addPath(torso); ctx.fillPath()
        ctx.addPath(torso); ctx.strokePath()
        if !mask {
            ctx.saveGState()
            ctx.addPath(torso); ctx.clip()
            if let g = gradient([rgb(1, 1, 1, 0.12), rgb(0, 0, 0, 0.18)]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: b.shoulder[0].x - 30, y: b.neck.y),
                                       end: CGPoint(x: b.shoulder[1].x + 30, y: b.neck.y), options: [])
            }
            ctx.restoreGState()
            // ベルト
            ctx.setStrokeColor(rgb(0.36, 0.24, 0.15))
            ctx.setLineWidth(12)
            ctx.setLineCap(.butt)
            ctx.move(to: CGPoint(x: b.hip[0].x - 30, y: b.hip[0].y + 8))
            ctx.addLine(to: CGPoint(x: b.hip[1].x + 30, y: b.hip[1].y + 8))
            ctx.strokePath()
            ctx.setLineCap(.round)
        }

        // 首と頭
        let headDir = CGPoint(x: sin(b.headAngle), y: cos(b.headAngle))
        ctx.setStrokeColor(skin)
        ctx.setLineWidth(36)
        ctx.move(to: b.neck); ctx.addLine(to: off(b.neck, headDir, 40)); ctx.strokePath()
        ctx.saveGState()
        ctx.translateBy(x: b.head.x, y: b.head.y)
        ctx.rotate(by: -CGFloat(b.headAngle))
        ctx.setFillColor(hair)
        ctx.fillEllipse(in: CGRect(x: -66, y: -58, width: 132, height: 140))
        ctx.setFillColor(skin)
        ctx.fillEllipse(in: CGRect(x: -68, y: -20, width: 20, height: 30))
        ctx.fillEllipse(in: CGRect(x: 48, y: -20, width: 20, height: 30))
        ctx.fillEllipse(in: CGRect(x: -56, y: -70, width: 112, height: 126))
        if !mask {
            // 前髪・目・口
            ctx.setFillColor(hair)
            ctx.fillEllipse(in: CGRect(x: -58, y: 24, width: 104, height: 52))
            ctx.fillEllipse(in: CGRect(x: -10, y: 20, width: 70, height: 44))
            ctx.setFillColor(rgb(0.12, 0.08, 0.07))
            ctx.fillEllipse(in: CGRect(x: -27, y: -4, width: 12, height: 14))
            ctx.fillEllipse(in: CGRect(x: 15, y: -4, width: 12, height: 14))
            ctx.setFillColor(rgb(0.95, 0.5, 0.45, 0.35))
            ctx.fillEllipse(in: CGRect(x: -42, y: -28, width: 20, height: 14))
            ctx.fillEllipse(in: CGRect(x: 22, y: -28, width: 20, height: 14))
            ctx.setStrokeColor(rgb(0.45, 0.17, 0.15))
            ctx.setLineWidth(4)
            ctx.move(to: CGPoint(x: -16, y: -38))
            ctx.addQuadCurve(to: CGPoint(x: 16, y: -38), control: CGPoint(x: 0, y: -52))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 腕（袖・肌・手）
        for i in 0..<2 {
            ctx.setStrokeColor(skin)
            ctx.setLineWidth(32)
            ctx.move(to: b.shoulder[i]); ctx.addLine(to: b.elbow[i]); ctx.addLine(to: b.wrist[i])
            ctx.strokePath()
            let sleeve = CGPoint(x: b.shoulder[i].x + (b.elbow[i].x - b.shoulder[i].x) * 0.55,
                                 y: b.shoulder[i].y + (b.elbow[i].y - b.shoulder[i].y) * 0.55)
            ctx.setStrokeColor(shirt)
            ctx.setLineWidth(44)
            ctx.move(to: b.shoulder[i]); ctx.addLine(to: sleeve)
            ctx.strokePath()
            ctx.setFillColor(skin)
            ctx.fillEllipse(in: CGRect(x: b.wrist[i].x - 20, y: b.wrist[i].y - 20, width: 40, height: 40))
        }
    }

    /// 部屋（窓・絵・鉢植え・木の床・ラグ）。一度だけ描く。
    /// 偽カメラの画素の箱と同じ並び（BGRA）にして、毎コマ写すときの変換をなくす
    static func room() -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let W = size.width, H = size.height
        let horizon: CGFloat = 430
        // 壁
        if let g = gradient([rgb(0.88, 0.85, 0.8), rgb(0.74, 0.69, 0.63)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: horizon), options: [])
        }
        // 窓から入る光
        if let g = gradient([rgb(1, 0.97, 0.88, 0.55), rgb(1, 0.97, 0.88, 0)]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 150, y: 900), startRadius: 0,
                                   endCenter: CGPoint(x: 150, y: 900), endRadius: 520, options: [])
        }
        // カーテンと窓
        ctx.setFillColor(rgb(0.55, 0.63, 0.56))
        ctx.fill(CGRect(x: 18, y: 660, width: 46, height: 480))
        ctx.fill(CGRect(x: 236, y: 660, width: 46, height: 480))
        ctx.setFillColor(rgb(0.96, 0.95, 0.92))
        ctx.fill(CGRect(x: 58, y: 710, width: 184, height: 380))
        if let g = gradient([rgb(0.62, 0.79, 0.93), rgb(0.88, 0.93, 0.96)]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 70, y: 722, width: 160, height: 356))
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 1078), end: CGPoint(x: 0, y: 722), options: [])
            // 遠くの木
            ctx.setFillColor(rgb(0.45, 0.62, 0.45, 0.8))
            ctx.fillEllipse(in: CGRect(x: 60, y: 700, width: 110, height: 120))
            ctx.fillEllipse(in: CGRect(x: 150, y: 690, width: 90, height: 100))
            ctx.restoreGState()
        }
        ctx.setFillColor(rgb(0.96, 0.95, 0.92))
        ctx.fill(CGRect(x: 146, y: 722, width: 8, height: 356))
        ctx.fill(CGRect(x: 70, y: 896, width: 160, height: 8))
        // 額の絵
        ctx.setFillColor(rgb(0.36, 0.26, 0.18))
        ctx.fill(CGRect(x: 470, y: 820, width: 170, height: 140))
        ctx.setFillColor(rgb(0.95, 0.93, 0.88))
        ctx.fill(CGRect(x: 482, y: 832, width: 146, height: 116))
        ctx.setFillColor(rgb(0.9, 0.62, 0.35))
        ctx.fillEllipse(in: CGRect(x: 500, y: 870, width: 56, height: 56))
        ctx.setFillColor(rgb(0.35, 0.5, 0.62))
        ctx.fill(CGRect(x: 540, y: 845, width: 70, height: 40))
        // 床（木）
        if let g = gradient([rgb(0.66, 0.5, 0.35), rgb(0.48, 0.34, 0.23)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: horizon), end: .zero, options: [])
        }
        // 板の目地（奥の一点に集まる）
        ctx.setStrokeColor(rgb(0.3, 0.2, 0.12, 0.3))
        ctx.setLineWidth(2)
        let vanish = CGPoint(x: W / 2, y: 1150)
        for i in stride(from: -900, through: 1620, by: 90) {
            let bottom = CGPoint(x: CGFloat(i), y: 0)
            // 目地は地平線から下だけ
            let k = (horizon - bottom.y) / (vanish.y - bottom.y)
            ctx.move(to: bottom)
            ctx.addLine(to: CGPoint(x: bottom.x + (vanish.x - bottom.x) * k, y: horizon))
        }
        ctx.strokePath()
        // 幅木
        ctx.setFillColor(rgb(0.95, 0.94, 0.9))
        ctx.fill(CGRect(x: 0, y: horizon - 4, width: W, height: 18))
        // 床に落ちる窓の光
        ctx.setFillColor(rgb(1, 0.97, 0.85, 0.12))
        ctx.move(to: CGPoint(x: 60, y: horizon))
        ctx.addLine(to: CGPoint(x: 240, y: horizon))
        ctx.addLine(to: CGPoint(x: 330, y: 120))
        ctx.addLine(to: CGPoint(x: 0, y: 120))
        ctx.closePath()
        ctx.fillPath()
        // ラグ
        ctx.setFillColor(rgb(0.38, 0.45, 0.55))
        ctx.fillEllipse(in: CGRect(x: 70, y: 200, width: 580, height: 200))
        ctx.setStrokeColor(rgb(0.9, 0.86, 0.76, 0.8))
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: CGRect(x: 90, y: 214, width: 540, height: 172))
        // 鉢植え
        ctx.setFillColor(rgb(0.3, 0.52, 0.32))
        for (x, y, r) in [(600.0, 560.0, 60.0), (560.0, 520.0, 48.0), (645.0, 515.0, 46.0), (610.0, 620.0, 40.0)] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        ctx.setFillColor(rgb(0.72, 0.42, 0.28))
        ctx.move(to: CGPoint(x: 550, y: 500))
        ctx.addLine(to: CGPoint(x: 660, y: 500))
        ctx.addLine(to: CGPoint(x: 645, y: 400))
        ctx.addLine(to: CGPoint(x: 565, y: 400))
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// 周りを少し暗くする（カメラで撮ったように）
    static func vignette(_ ctx: CGContext) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let g = gradient([rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.32)]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 420, endCenter: center, endRadius: 820,
                               options: [.drawsAfterEndLocation])
    }
}

/// デモの当てる人の顔（内側のカメラの代わり）。画面を見たまま、目だけ動き、叫んだり驚いたり笑ったりする。
/// 顔は上を向かない（鼻・目・口の上下の並びが変わらない）ので、カンニングの見張りは鳴らない
enum DemoFace {
    static let size = CGSize(width: 480, height: 640)

    private enum Mood { case shout, think, surprised, laugh }

    static func draw(at t: Double, in ctx: CGContext) {
        let W = size.width, H = size.height
        let segment = Int(floor(t / 1.7))
        let r = noise(segment)
        let mood: Mood = r < 0.4 ? .shout : r < 0.6 ? .think : r < 0.8 ? .surprised : .laugh
        let local = t - Double(segment) * 1.7

        // 後ろの部屋（暗めの天井と、右上の電灯）
        if let g = gradient([rgb(0.24, 0.26, 0.32), rgb(0.38, 0.33, 0.3)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: .zero, options: [])
        }
        if let g = gradient([rgb(1, 0.86, 0.62, 0.45), rgb(1, 0.86, 0.62, 0)]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 400, y: 600), startRadius: 0,
                                   endCenter: CGPoint(x: 400, y: 600), endRadius: 300, options: [])
        }

        // 頭の揺れ（左右と傾きだけ。上下には向かない）
        var hx = W / 2 + CGFloat(14 * sin(t * 0.9))
        let hy: CGFloat = 350 + CGFloat(5 * sin(t * 1.3))
        var roll = 0.05 * sin(t * 0.7)
        if mood == .laugh {
            roll += 0.08 * sin(t * 14)
            hx += CGFloat(6 * sin(t * 14))
        }

        // 肩（セーター）と首
        ctx.setFillColor(rgb(0.29, 0.41, 0.6))
        ctx.fillEllipse(in: CGRect(x: hx * 0.4 + 144 - 270, y: -190, width: 540, height: 320))
        ctx.setFillColor(rgb(0.84, 0.64, 0.5))
        ctx.fill(CGRect(x: hx - 46, y: 100, width: 92, height: hy - 150))
        ctx.setFillColor(rgb(0.22, 0.32, 0.5))
        ctx.fillEllipse(in: CGRect(x: hx - 70, y: 92, width: 140, height: 40))

        ctx.saveGState()
        ctx.translateBy(x: hx, y: hy)
        ctx.rotate(by: CGFloat(roll))
        let skin = rgb(0.93, 0.76, 0.62), hair = rgb(0.16, 0.1, 0.08)
        // 後ろ髪・耳・顔
        ctx.setFillColor(hair)
        ctx.fillEllipse(in: CGRect(x: -150, y: -140, width: 300, height: 340))
        ctx.setFillColor(skin)
        ctx.fillEllipse(in: CGRect(x: -146, y: -34, width: 40, height: 62))
        ctx.fillEllipse(in: CGRect(x: 106, y: -34, width: 40, height: 62))
        ctx.fillEllipse(in: CGRect(x: -125, y: -165, width: 250, height: 310))
        // 顔の陰（右側を少し暗く）
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: -125, y: -165, width: 250, height: 310))
        ctx.clip()
        if let g = gradient([rgb(1, 1, 1, 0.08), rgb(0.4, 0.2, 0.1, 0.18)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: -125, y: 0), end: CGPoint(x: 125, y: 0), options: [])
        }
        ctx.restoreGState()
        // 前髪
        ctx.setFillColor(hair)
        ctx.fillEllipse(in: CGRect(x: -135, y: 75, width: 270, height: 130))
        ctx.fillEllipse(in: CGRect(x: -150, y: 60, width: 150, height: 110))

        // 眉（驚くと上がる。考えると内側が下がる）
        let raise: CGFloat = mood == .surprised ? 14 : mood == .shout ? 5 : 0
        let frown: CGFloat = mood == .think ? -6 : 0
        ctx.setStrokeColor(hair)
        ctx.setLineCap(.round)
        ctx.setLineWidth(10)
        for s: CGFloat in [-1, 1] {
            ctx.move(to: CGPoint(x: s * 28, y: 58 + raise + frown))
            ctx.addLine(to: CGPoint(x: s * 80, y: 56 + raise))
            ctx.strokePath()
        }

        // 目（左右を見回す。たまにまばたき。笑うと細くなる）
        let blink = (t / 3.1 - floor(t / 3.1)) < 0.045
        let gazeX: CGFloat
        let gazeY: CGFloat
        switch mood {
        case .think: gazeX = CGFloat(sin(t * 1.6)); gazeY = -0.6
        case .shout: gazeX = CGFloat(0.3 * sin(t * 2)); gazeY = -0.3
        default: gazeX = CGFloat(0.4 * sin(t * 0.8)); gazeY = -0.2
        }
        let open: CGFloat = mood == .surprised ? 1.3 : 1
        for s: CGFloat in [-1, 1] {
            let ex = s * 52, ey: CGFloat = 22
            if mood == .laugh || blink {
                ctx.setStrokeColor(rgb(0.2, 0.12, 0.1))
                ctx.setLineWidth(6)
                ctx.move(to: CGPoint(x: ex - 22, y: ey))
                ctx.addQuadCurve(to: CGPoint(x: ex + 22, y: ey), control: CGPoint(x: ex, y: mood == .laugh ? ey + 18 : ey - 6))
                ctx.strokePath()
                continue
            }
            let eye = CGRect(x: ex - 25, y: ey - 15 * open, width: 50, height: 30 * open)
            ctx.setFillColor(rgb(0.98, 0.97, 0.95))
            ctx.fillEllipse(in: eye)
            ctx.saveGState()
            ctx.addEllipse(in: eye)
            ctx.clip()
            let ix = ex + gazeX * 10, iy = ey + gazeY * 4
            ctx.setFillColor(rgb(0.33, 0.2, 0.12))
            ctx.fillEllipse(in: CGRect(x: ix - 12, y: iy - 12, width: 24, height: 24))
            ctx.setFillColor(rgb(0.05, 0.03, 0.03))
            ctx.fillEllipse(in: CGRect(x: ix - 6, y: iy - 6, width: 12, height: 12))
            ctx.setFillColor(rgb(1, 1, 1))
            ctx.fillEllipse(in: CGRect(x: ix + 2, y: iy + 3, width: 5, height: 5))
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(0.25, 0.14, 0.1))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: eye)
        }

        // 鼻と頬
        ctx.setStrokeColor(rgb(0.72, 0.5, 0.38))
        ctx.setLineWidth(5)
        ctx.move(to: CGPoint(x: -4, y: 2))
        ctx.addQuadCurve(to: CGPoint(x: -12, y: -34), control: CGPoint(x: -14, y: -14))
        ctx.addQuadCurve(to: CGPoint(x: 12, y: -36), control: CGPoint(x: 0, y: -42))
        ctx.strokePath()
        ctx.setFillColor(rgb(0.95, 0.5, 0.45, 0.25))
        ctx.fillEllipse(in: CGRect(x: -102, y: -66, width: 44, height: 34))
        ctx.fillEllipse(in: CGRect(x: 58, y: -66, width: 44, height: 34))

        // 口。中心は動かさず、上下に同じだけ開く（口の位置で顔の向きを測る見張りを揺らさない）
        let mouth = CGPoint(x: 0, y: -88)
        var o: Double
        var width: CGFloat = 76
        switch mood {
        case .shout: o = 0.3 + 0.6 * abs(sin(t * 7))
        case .think: o = 0
        case .surprised: o = 0.75; width = 50
        case .laugh: o = 0.5 + 0.3 * abs(sin(t * 12)); width = 96
        }
        // 切り替わりの頭はふわっと開く
        o *= smooth(local / 0.25)
        if o < 0.05 {
            ctx.setStrokeColor(rgb(0.55, 0.2, 0.2))
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: mouth.x - 34, y: mouth.y + 4))
            ctx.addQuadCurve(to: CGPoint(x: mouth.x + 34, y: mouth.y + 4), control: CGPoint(x: mouth.x, y: mouth.y - 12))
            ctx.strokePath()
        } else {
            let height = 10 + 62 * CGFloat(o)
            let rect = CGRect(x: mouth.x - width / 2, y: mouth.y - height / 2, width: width, height: height)
            ctx.setFillColor(rgb(0.33, 0.07, 0.1))
            ctx.fillEllipse(in: rect)
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            ctx.setFillColor(rgb(0.97, 0.96, 0.94))
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 12, width: rect.width, height: 12))
            ctx.setFillColor(rgb(0.86, 0.42, 0.45))
            ctx.fillEllipse(in: CGRect(x: mouth.x - width * 0.35, y: rect.minY - height * 0.2, width: width * 0.7, height: height * 0.55))
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(0.72, 0.36, 0.36))
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }
}

/// 試験用：ハイライトが作れないとき、どこで失敗するかを部品ごとに試して文にする
enum ExportProbe {
    static func run(raw: URL, seen: URL?, clips: [Highlight.Clip]) async -> String {
        var lines: [String] = []
        for (name, url) in [("生", raw), ("見えていた画面", seen)] {
            guard let url else { lines.append("\(name)：なし"); continue }
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let range = try? await track.load(.timeRange),
               let duration = try? await asset.load(.duration) {
                lines.append("\(name)：\(Int(size.width))x\(Int(size.height)) 長さ \(fmt(duration.seconds)) 映像 \(fmt(range.start.seconds))〜\(fmt(range.end.seconds))")
            } else {
                lines.append("\(name)：読めない")
            }
        }
        lines.append("場面：" + clips.map { "\(fmt($0.start))〜\(fmt($0.end))" }.joined(separator: ","))
        let asset = AVURLAsset(url: raw)
        lines.append("生をそのまま mp4：" + (await export(asset, preset: AVAssetExportPresetHighestQuality, as: .mp4)))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return lines.joined(separator: "／") }
        if let ts = try? await track.load(.naturalTimeScale), let fd = try? await track.load(.minFrameDuration) {
            lines.append("時間の目盛り \(ts)・最短のコマ \(fd.value)/\(fd.timescale)")
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        // 合成：まるごと 1 本／場面ごとに切ってつなぐ
        for cut in [false, true] {
            let comp = AVMutableComposition()
            guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor = CMTime.zero
            var ranges: [CMTimeRange] = []
            let parts: [(Double, Double)] = cut ? clips.map { (max($0.end - 3.5, $0.start, 0), min($0.end + 0.8, duration.seconds)) } : [(0, duration.seconds)]
            for (from, to) in parts {
                let r = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
                do { try t.insertTimeRange(r, of: track, at: cursor) } catch { lines.append("入れられない \((error as NSError).code)"); continue }
                ranges.append(CMTimeRange(start: cursor, duration: r.duration))
                cursor = cursor + r.duration
            }
            let name = cut ? "切って合成" : "まるごと合成"
            lines.append("\(name)（長さ \(String(format: "%.2f", comp.duration.seconds))）：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4)))
            // 自動の指示
            guard let auto = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp) else { continue }
            lines.append("\(name)＋自動の指示（\(auto.instructions.count)）：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4, video: auto)))
            // ハイライトと同じ手書きの指示
            let manual = AVMutableVideoComposition()
            manual.renderSize = auto.renderSize
            manual.frameDuration = CMTime(value: 1, timescale: 30)
            manual.instructions = ranges.map { r in
                let i = AVMutableVideoCompositionInstruction()
                i.timeRange = r
                let l = AVMutableVideoCompositionLayerInstruction(assetTrack: t)
                l.setTransform(.identity, at: r.start)
                i.layerInstructions = [l]
                return i
            }
            lines.append("\(name)＋手書きの指示：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4, video: manual)))
            // 指示を 1 つにまとめる
            let single = AVMutableVideoComposition()
            single.renderSize = auto.renderSize
            single.frameDuration = CMTime(value: 1, timescale: 30)
            let i = AVMutableVideoCompositionInstruction()
            i.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            i.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: t)]
            single.instructions = [i]
            lines.append("\(name)＋指示 1 つ：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4, video: single)))
        }
        return lines.joined(separator: "／")
    }

    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType,
                               video: AVVideoComposition? = nil) async -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).\(type == .mp4 ? "mp4" : "mov")")
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return "作れない" }
        session.videoComposition = video
        do {
            try await session.export(to: out, as: type)
            return "成功"
        } catch {
            let e = error as NSError
            let u = e.userInfo[NSUnderlyingErrorKey] as? NSError
            return "失敗 \(e.code)" + (u.map { " ← \($0.code)" } ?? "")
        }
    }

    private static func fmt(_ t: Double) -> String { String(format: "%.2f", t) }
}
