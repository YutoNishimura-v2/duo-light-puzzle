@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision
import VideoToolbox

/// 当てる人に見せる映りのしばり（おまけ。基本はしばりなしで、人そのものを見せる）。
/// 並びはホームのモード列の順。背景を変えるもの → 姿を変えるもの
enum Effect: String, CaseIterable, Identifiable, Sendable {
    case space, sea, classroom, stage
    case stick, silhouette, mosaic, delay, peephole

    var id: String { rawValue }

    /// 日本語の名前。訳の表（Localizable.strings）の鍵にもなる
    var name: String {
        switch self {
        case .space: "宇宙"
        case .sea: "海"
        case .classroom: "教室"
        case .stage: "ステージ"
        case .stick: "棒人間"
        case .silhouette: "影絵"
        case .mosaic: "モザイク"
        case .delay: "3秒遅れ"
        case .peephole: "のぞき穴"
        }
    }

    /// 人はそのまま映し、うしろの景色だけ差し替える
    var isBackground: Bool {
        switch self {
        case .space, .sea, .classroom, .stage: true
        default: false
        }
    }

    /// 画面に出す名前（端末の言葉）
    var label: String { NSLocalizedString(name, comment: "しばりの名前") }

    /// 決めた言葉での名前（種明かし動画は山札の言葉で書く）
    func label(language: String) -> String { Words.text(name, language: language) }
}

/// しばりの画面に人が映っていたかのまとめ（ハイライトでお題を選ぶのに使う）
struct SeenQuality: Sendable, Equatable {
    /// 人が映っていた時間の割合（0〜1）
    var visibleFraction: Double
    /// 人が映っていなかった時間の、いちばん長い続き（秒）
    var longestEmpty: Double
    /// 1 秒以上なにも映らない時間があった（種明かしが空の画面になる）
    var hasEmptyGap: Bool { longestEmpty >= 1 }

    /// しばりなし・記録なしのときは全部映っていたことにする
    static let full = SeenQuality(visibleFraction: 1, longestEmpty: 0)
}

/// しばりの画面に人が映っていたかの記録。時刻は録画と同じ時計（systemUptime と同じ、フレームの時刻）の秒
final class SeenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(t: TimeInterval, visible: Bool)] = []
    /// 記録は 10 回/秒まで（映り方が変わったときだけは間をあけずに残す）
    static let interval = 0.1
    /// これより間があいたら、そのあいだは映っていなかったことにする（絵が出ていない）
    static let stale = 0.5

    /// ラウンドの頭で空にする
    func reset() {
        lock.withLock { samples.removeAll() }
    }

    func add(_ t: TimeInterval, visible: Bool) {
        lock.withLock {
            if let last = samples.last {
                if t < last.t { return }
                if t - last.t < Self.interval && last.visible == visible { return }
            }
            samples.append((t, visible))
            // 長いラウンドでも増えすぎないように（10 分ぶん程度で古いものから捨てる）
            if samples.count > 6000 { samples.removeFirst(1000) }
        }
    }

    /// from〜to（録画と同じ時計の秒）に人が映っていた割合と、映っていなかったいちばん長い続き
    func quality(from: TimeInterval, to: TimeInterval) -> SeenQuality {
        guard to > from else { return .full }
        let list = lock.withLock { samples }
        let step = 0.05
        var visible = 0.0, run = 0.0, longest = 0.0
        var i = 0
        var t = from
        // 区間を 0.05 秒ずつ刻み、そのときの直前の記録で映っていたかを見る
        while t < to {
            while i < list.count && list[i].t <= t { i += 1 }
            var on = false
            if i > 0 {
                let last = list[i - 1]
                on = last.visible && t - last.t < Self.stale
            }
            let d = min(step, to - t)
            if on {
                visible += d
                run = 0
            } else {
                run += d
                longest = max(longest, run)
            }
            t += step
        }
        return SeenQuality(visibleFraction: min(visible / (to - from), 1), longestEmpty: longest)
    }
}

/// 背面カメラのフレームにしばりをかける。重い処理なので専用のキューで、追いつかないフレームは捨てる
final class EffectEngine: @unchecked Sendable {
    /// しばりの画面に人が映っていたかの記録（ラウンド終わりに Game が読む）
    static let seenLog = SeenLog()
    /// 棒人間：この数以上の関節が見つかれば人が映っていたことにする
    static let minJoints = 5
    /// 影絵・背景：人の形が画面のこの割合より多ければ映っていたことにする
    static let minCoverage = 0.02

    /// アプリで 1 つだけ使う Core Image の描き手（小窓の縮小もこれを使う）。
    /// 描き手ごとに GPU の作業場を持つので、増やさない。途中の絵は残さない。
    /// 途中の絵は 8 ビットで持つ（標準の 16 ビット浮動小数の半分のメモリ）。暗い色に段がつかないよう sRGB のまま混ぜる
    nonisolated(unsafe) static let sharedContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingFormat: CIFormat.RGBA8.rawValue,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .useSoftwareRenderer: false,
    ])

    /// シミュレータのデモでは Vision を回さず、役者の骨組み・型抜きだけを使う。
    /// シミュレータの Vision は人を見つけられないことが多く、CPU で動くので重い（読み取りの作業場で数百 MB 使う）。
    /// 実機では、デモでも本物の Vision を回す
    #if targetEnvironment(simulator)
    static let usesVision = !FakeCamera.isDemo
    #else
    static let usesVision = true
    #endif

    private let queue = DispatchQueue(label: "effects", qos: .userInitiated)
    private let lock = NSLock()
    private let context = EffectEngine.sharedContext
    private var busy = false
    private var effect: Effect?
    private var promptStart: TimeInterval = 0
    /// 3 秒遅れの絵。effects キューだけで触る。
    /// 処理の大きさの 2/3（540x960 なら 360x640）を YUV の画素の箱（1 画素 1.5 バイト、約 0.35 MB）で、3 秒ぶん（約 46 枚）だけ持つ
    private var history: [(t: TimeInterval, buffer: CVPixelBuffer)] = []
    private var historyPool: CVPixelBufferPool?
    private var historyPoolSize: CGSize = .zero
    /// しばりが変わったら、次の処理で history を空にする（lock で守る）
    private var clearHistory = false
    private var lastHistory: TimeInterval = 0
    /// 背景の絵（一度描いたら使い回す）。いまのしばりの 1 枚だけ持つ。effects キューだけで触る
    private var background: (effect: Effect, size: CGSize, image: CIImage)?
    /// main に渡したしばりの画面がまだ受け取られていない（lock で守る）。
    /// main が追いつかないときは新しい画面を渡さない（Task と画素の箱が積み上がってメモリが増え続けないように）
    private var frameInFlight = false

    /// 棒人間・デモの型抜きを描く画素の箱（毎コマ新しい CGImage を作らない）。effects キューだけで触る
    private var stickPool: CVPixelBufferPool?
    private var stickPoolSize: CGSize = .zero
    private var maskPool: CVPixelBufferPool?
    private var maskPoolSize: CGSize = .zero

    /// デモだけ：Vision の読み取りを間引く。effects キューだけで触る
    /// 最後に Vision が見つけた人の型抜きと、その時刻
    private var lastPersonMask: CVPixelBuffer?
    private var lastPersonTime: TimeInterval = 0
    /// Vision が人を見つけられなかったら、この時刻までは Vision を回さず役者の型抜き・骨組みを使う
    private var personRetryAt: TimeInterval = 0
    private var bodyRetryAt: TimeInterval = 0
    /// デモで Vision を回す間隔（見つけているとき）と、見つからなかったときに待つ時間
    static let demoVisionInterval = 1.0 / 12
    static let demoVisionRetry = 1.0

    /// Vision の読み取り。使うときに作る（メモリが足りないときは手放して、次に使うとき作り直す）。effects キューだけで触る
    private var bodyRequestStore: VNDetectHumanBodyPoseRequest?
    private var personRequestStore: VNGeneratePersonSegmentationRequest?
    private var bodyRequest: VNDetectHumanBodyPoseRequest {
        if let r = bodyRequestStore { return r }
        let r = VNDetectHumanBodyPoseRequest()
        bodyRequestStore = r
        return r
    }
    private var personRequest: VNGeneratePersonSegmentationRequest {
        if let r = personRequestStore { return r }
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        personRequestStore = r
        return r
    }

    /// 3 秒遅れの絵を持つ大きさ（処理の大きさに対する割合）と、1 秒に残す枚数
    static let historyScale: CGFloat = 2.0 / 3.0
    static let historyFPS = 15.0

    /// しばりをかけた画面（main で呼ぶ）
    var onFrame: (@MainActor (CGImage) -> Void)?
    /// 録画用（effects キューで呼ぶ）。しばりをかけた画面を同じ時刻で書く
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?

    /// 処理する大きさ（長い辺）。Vision も描画もこの大きさで行う
    static let longSide: CGFloat = 960
    static let delaySeconds = 3.0

    func set(effect: Effect?, promptStart: TimeInterval) {
        let changed: Bool = lock.withLock {
            let changed = self.effect != effect
            if changed { clearHistory = true }
            self.effect = effect
            self.promptStart = promptStart
            return changed
        }
        // しばりなしになったら、持っている絵をすぐ手放す（なしの間は process が動かず、空にする機会がない）
        if changed, effect == nil { purge(vision: false) }
    }

    /// 持っている絵と Core Image の作業場を手放す。vision なら Vision の読み取り（学習済みの型）も手放す。
    /// ラウンドの終わり（種明かしを書き出す前）と、メモリが足りないと言われたときに呼ぶ。どのスレッドからでもよい
    func purge(vision: Bool) {
        queue.async { [self] in
            dropEffectState()
            pool = nil
            poolSize = .zero
            if vision {
                bodyRequestStore = nil
                personRequestStore = nil
            }
            context.clearCaches()
        }
    }

    /// しばりごとに持つもの（3 秒遅れの絵・背景・棒人間と型抜きの箱）を手放す。effects キューで呼ぶ
    private func dropEffectState() {
        history.removeAll()
        lastHistory = 0
        historyPool = nil
        historyPoolSize = .zero
        background = nil
        stickPool = nil
        stickPoolSize = .zero
        maskPool = nil
        maskPoolSize = .zero
        lastPersonMask = nil
    }

    /// カメラのキューから呼ぶ
    func process(_ buffer: CVPixelBuffer, time: CMTime) {
        let (effect, start, skip, clear): (Effect?, TimeInterval, Bool, Bool) = lock.withLock {
            if busy || effect == nil { return (nil, 0, true, false) }
            busy = true
            let clear = clearHistory
            clearHistory = false
            return (self.effect, promptStart, false, clear)
        }
        guard !skip, let effect else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            // コマごとの一時的な絵（Vision・Core Image の中身）を、このコマの終わりで手放す
            autoreleasepool {
                if clear {
                    // しばりが変わったら、前のしばりの絵と箱、Core Image が持っていた絵を手放す（2 秒ごとの切り替えでも軽い）
                    dropEffectState()
                    if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) }
                    context.clearCaches()
                }
                let now = ProcessInfo.processInfo.systemUptime
                let input = Self.downscaled(CIImage(cvPixelBuffer: buffer))
                let rendered = render(effect, input: input, source: buffer, now: now, elapsed: now - start, frameTime: time.seconds)
                // 人が映っていたかを、録画と同じフレームの時刻で残す
                Self.seenLog.add(time.seconds, visible: rendered.visible)
                let output = rendered.image.cropped(to: input.extent)
                // 出口の箱は、録画の符号化と画面が持っている分だけ（6 枚まで）。足りなければこのコマは捨てる
                guard let pb = Self.pooledBuffer(&pool, &poolSize, size: input.extent.size,
                                                 format: kCVPixelFormatType_32BGRA, limit: 6) else { return }
                context.render(output, to: pb)
                onPixelBuffer?(pb, time)
                // 前の画面を main がまだ受け取っていなければ、この画面は見せない（録画には上で書いてある）
                let send: Bool = lock.withLock {
                    if frameInFlight { return false }
                    frameInFlight = true
                    return true
                }
                guard send else { return }
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
                guard let cg else {
                    lock.withLock { frameInFlight = false }
                    return
                }
                Task { @MainActor [onFrame, weak self] in
                    onFrame?(cg)
                    self?.frameDelivered()
                }
            }
        }
    }

    /// main が画面を受け取った（main で呼ぶ）
    private func frameDelivered() {
        lock.withLock { frameInFlight = false }
    }

    // MARK: しばりごとの絵

    /// visible は人が映っていたか（棒人間・影絵・背景だけ見分ける。ほかはいつも映っている）
    /// frameTime はフレームの時刻（デモでは、この時刻の役者の骨組み・型抜きを使う）
    private func render(_ effect: Effect, input: CIImage, source: CVPixelBuffer, now: TimeInterval, elapsed: TimeInterval,
                        frameTime: TimeInterval) -> (image: CIImage, visible: Bool) {
        let black = CIImage(color: .black).cropped(to: input.extent)
        if effect.isBackground {
            return backdrop(effect, source: source, input: input, now: now, frameTime: frameTime, black: black)
        }
        switch effect {
        case .stick:
            let stick = stickFigure(source: source, size: input.extent.size, now: now, frameTime: frameTime)
            return (stick.image ?? black, stick.found)
        case .silhouette:
            let shadow = silhouette(source: source, input: input, now: now, frameTime: frameTime)
            return (shadow.image ?? black, shadow.found)
        default:
            return (plain(effect, input: input, now: now, elapsed: elapsed, black: black), true)
        }
    }

    private func plain(_ effect: Effect, input: CIImage, now: TimeInterval, elapsed: TimeInterval, black: CIImage) -> CIImage {
        switch effect {
        case .stick, .silhouette, .space, .sea, .classroom, .stage:
            return black
        case .mosaic:
            // 最初は粗く、25 秒かけて細かくなる（早く当てるほど難しい画面で当てたことになる）
            let progress = min(max(elapsed / 25, 0), 1)
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(90 - 78 * progress)
            f.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
            return f.outputImage ?? black
        case .delay:
            return delayed(input, now: now) ?? black.composited(over: black)
        case .peephole:
            // 小さな丸い窓がゆっくりうろつく
            let size = input.extent.size
            let r = min(size.width, size.height) * 0.17
            let center = CGPoint(x: size.width * (0.5 + 0.32 * sin(now * 0.9)),
                                 y: size.height * (0.5 + 0.3 * sin(now * 1.3 + 1)))
            let g = CIFilter.radialGradient()
            g.center = center
            g.radius0 = Float(r * 0.92)
            g.radius1 = Float(r)
            g.color0 = .white
            g.color1 = .black
            let mask = g.outputImage?.cropped(to: input.extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = input
            blend.backgroundImage = black
            blend.maskImage = mask
            return blend.outputImage ?? black
        }
    }

    private func delayed(_ input: CIImage, now: TimeInterval) -> CIImage? {
        // 15 コマ/秒だけ、2/3 の大きさに縮めて残す（メモリを食いすぎないように、描き終えた絵として持つ）。
        // YUV の画素の箱に描く：BGRA の CGImage より小さく（1.5 バイト/画素）、Core Image が GPU に写し直す分も要らない
        let s = Self.historyScale
        if now - lastHistory >= 1.0 / Self.historyFPS {
            let small = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let rect = small.extent.integral
            // YUV 4:2:0 は幅と高さを偶数にする
            let size = CGSize(width: (rect.width / 2).rounded(.down) * 2, height: (rect.height / 2).rounded(.down) * 2)
            let most = Int(Self.delaySeconds * Self.historyFPS) + 6
            if let pb = Self.pooledBuffer(&historyPool, &historyPoolSize, size: size,
                                          format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, limit: most) {
                context.render(small.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)), to: pb)
                history.append((now, pb))
                lastHistory = now
            }
        }
        // 3 秒より古い絵はもう出さない（now は増えるだけなので）。いちばん新しい 1 枚は空にしないよう残す
        while history.count > 1, now - history[0].t > Self.delaySeconds { history.removeFirst() }
        // 念のため枚数にも上限（3 秒ぶん＋ゆとり）
        let cap = Int(Self.delaySeconds * Self.historyFPS) + 4
        if history.count > cap { history.removeFirst(history.count - cap) }
        guard let first = history.first, now - first.t <= Self.delaySeconds else { return nil }
        // 処理の大きさへ戻す
        let back = CIImage(cvPixelBuffer: first.buffer).transformed(by: CGAffineTransform(scaleX: 1 / s, y: 1 / s))
        return back.transformed(by: CGAffineTransform(translationX: input.extent.minX - back.extent.minX,
                                                      y: input.extent.minY - back.extent.minY))
    }

    /// 人の形の型抜き（白が人、input の大きさ）。found は人の形が画面に十分あったか
    /// デモでは Vision を間引く：見つけているときは 12 回/秒まで（間は前の型抜きを使う）、
    /// 見つからなかったら 1 秒は Vision を回さず役者の型抜きを使う（シミュレータの Vision は人を見つけず、重いだけ）
    private func personMask(source: CVPixelBuffer, input: CIImage, now: TimeInterval,
                            frameTime: TimeInterval) -> (mask: CIImage?, found: Bool) {
        let demo = FakeCamera.isDemo
        var maskBuffer: CVPixelBuffer?
        var found = false
        if !Self.usesVision {
            // シミュレータのデモ：Vision は使わない（下で役者の型抜きを使う）
        } else if demo, now < personRetryAt {
            // Vision は休み（下で役者の型抜きを使う）
        } else if demo, let last = lastPersonMask, now - lastPersonTime < Self.demoVisionInterval {
            maskBuffer = last
            found = true
        } else {
            let handler = VNImageRequestHandler(cvPixelBuffer: source)
            try? handler.perform([personRequest])
            if let m = personRequest.results?.first?.pixelBuffer {
                maskBuffer = m
                found = Self.coverage(m) > Self.minCoverage
            }
            if demo {
                if found {
                    lastPersonMask = maskBuffer
                    lastPersonTime = now
                } else {
                    lastPersonMask = nil
                    personRetryAt = now + Self.demoVisionRetry
                }
            }
        }
        var mask: CIImage?
        if let maskBuffer {
            let m = CIImage(cvPixelBuffer: maskBuffer)
            mask = m.transformed(by: CGAffineTransform(scaleX: input.extent.width / m.extent.width,
                                                       y: input.extent.height / m.extent.height))
        }
        // デモ：Vision が人を見つけられないときは、偽カメラの役者の型抜きを使う。
        // 型抜きは使い回しの画素の箱に半分の大きさで描く（毎コマ新しい CGImage を作ると Core Image が抱え込む）
        if !found, demo {
            let size = CGSize(width: (input.extent.width / 2).rounded(), height: (input.extent.height / 2).rounded())
            if let pb = Self.pooledBuffer(&maskPool, &maskPoolSize, size: size, format: kCVPixelFormatType_OneComponent8,
                                             limit: 3),
               DemoActor.mask(at: frameTime, into: pb) {
                let m = CIImage(cvPixelBuffer: pb)
                mask = m.transformed(by: CGAffineTransform(scaleX: input.extent.width / m.extent.width,
                                                           y: input.extent.height / m.extent.height))
                found = true
            }
        }
        return (mask, found)
    }

    /// found は人の形が画面に十分あったか
    private func silhouette(source: CVPixelBuffer, input: CIImage, now: TimeInterval,
                            frameTime: TimeInterval) -> (image: CIImage?, found: Bool) {
        let person = personMask(source: source, input: input, now: now, frameTime: frameTime)
        guard let mask = person.mask else { return (nil, false) }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.08)).cropped(to: input.extent)
        blend.backgroundImage = CIImage(color: CIColor(red: 0.96, green: 0.93, blue: 0.85)).cropped(to: input.extent)
        blend.maskImage = mask
        return (blend.outputImage, person.found)
    }

    /// 本物の人（カメラの画素そのまま）を、描いておいた背景の上に切り抜いて置く。
    /// 人が見つからないときは背景だけ（visible は false）
    private func backdrop(_ effect: Effect, source: CVPixelBuffer, input: CIImage, now: TimeInterval, frameTime: TimeInterval,
                          black: CIImage) -> (image: CIImage, visible: Bool) {
        // 大きさは整数に丸めて比べる（小数のぶれで描き直さない）。いまのしばりの 1 枚だけ持つ
        let size = CGSize(width: input.extent.width.rounded(), height: input.extent.height.rounded())
        var scene = black
        if let cached = background, cached.effect == effect, cached.size == size {
            scene = cached.image
        } else {
            // 前の背景を先に手放してから描く（2 枚を同時に持たない）
            background = nil
            if let pb = Self.backdropBuffer(effect, size: size) {
                scene = CIImage(cvPixelBuffer: pb)
                background = (effect, size, scene)
            }
        }
        let person = personMask(source: source, input: input, now: now, frameTime: frameTime)
        guard let mask = person.mask else { return (scene, false) }
        // 型抜きは小さい絵を引き伸ばしたものなので、縁に元の部屋（明るい壁）の画素がにじみ、人の周りに白い縁が出ていた。
        // 型抜きを内側へ少し縮めてから、細くぼかす（縁は背景の色に溶ける）
        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = mask.clampedToExtent()
        erode.radius = Float(max(1.5, input.extent.width * 0.004))
        let shrunk = erode.outputImage ?? mask.clampedToExtent()
        let soft = shrunk.applyingGaussianBlur(sigma: 1.0).cropped(to: input.extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = input
        blend.backgroundImage = scene
        blend.maskImage = soft
        return (blend.outputImage ?? scene, person.found)
    }

    /// 背景を画素の箱（BGRA）に直接描く。CGImage を作らず、Core Image も GPU に写し直さずに読める
    private static func backdropBuffer(_ effect: Effect, size: CGSize) -> CVPixelBuffer? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        Backdrop.draw(effect, in: ctx, width: w, height: h)
        ctx.flush()
        return pb
    }

    /// 人の形の割合（0〜1）。8 ビットの型抜きを 4 画素おきに数える
    private static func coverage(_ mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return 0 }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var on = 0, all = 0
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                all += 1
                if pixels[y * row + x] > 127 { on += 1 }
            }
        }
        return all > 0 ? Double(on) / Double(all) : 0
    }

    /// 骨組みだけを描く。found は関節が十分に見つかったか
    private func stickFigure(source: CVPixelBuffer, size: CGSize, now: TimeInterval,
                             frameTime: TimeInterval) -> (image: CIImage?, found: Bool) {
        let demo = FakeCamera.isDemo
        var found = false
        // 人ごとの関節（確かなものだけ。0〜1、左下が原点）
        var bodies: [[VNHumanBodyPoseObservation.JointName: CGPoint]] = []
        // デモで Vision が人を見つけられなかった直後は、しばらく Vision を回さない
        if Self.usesVision, !(demo && now < bodyRetryAt) {
            let handler = VNImageRequestHandler(cvPixelBuffer: source)
            try? handler.perform([bodyRequest])
            for body in bodyRequest.results ?? [] {
                guard let points = try? body.recognizedPoints(.all) else { continue }
                var sure: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
                for (name, pt) in points where pt.confidence > 0.2 { sure[name] = pt.location }
                if sure.count >= Self.minJoints { found = true }
                bodies.append(sure)
            }
            if demo, !found { bodyRetryAt = now + Self.demoVisionRetry }
        }
        // デモ：Vision が人を見つけられないときは、偽カメラの役者の骨組みを使う
        if !found, demo {
            bodies = [DemoActor.joints(at: frameTime)]
            found = true
        }
        // 使い回しの画素の箱（BGRA）に描く。毎コマ新しい CGImage を作ると Core Image が抱え込む
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let pb = Self.pooledBuffer(&stickPool, &stickPoolSize, size: CGSize(width: w, height: h),
                                         format: kCVPixelFormatType_32BGRA, limit: 3) else { return (nil, found) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (nil, found) }
        ctx.setFillColor(UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let line = max(CGFloat(w) / 45, 6)
        for points in bodies {
            // Vision の座標は左下が原点の 0〜1。CGContext も左下が原点なのでそのまま掛ける
            func p(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let pt = points[name] else { return nil }
                return CGPoint(x: pt.x * CGFloat(w), y: pt.y * CGFloat(h))
            }
            let bones: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
                (.neck, .root),
                (.neck, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
                (.neck, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
                (.root, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
                (.root, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
            ]
            ctx.setStrokeColor(UIColor(red: 1, green: 0.87, blue: 0.43, alpha: 1).cgColor)
            ctx.setLineWidth(line)
            for (a, b) in bones {
                guard let pa = p(a), let pb = p(b) else { continue }
                ctx.move(to: pa)
                ctx.addLine(to: pb)
                ctx.strokePath()
            }
            // 頭は首と鼻から丸で描く
            if let neck = p(.neck), let nose = p(.nose) {
                let r = max(hypot(nose.x - neck.x, nose.y - neck.y) * 0.9, line * 2)
                ctx.setLineWidth(line)
                ctx.strokeEllipse(in: CGRect(x: nose.x - r, y: nose.y - r, width: r * 2, height: r * 2))
            }
        }
        ctx.flush()
        return (CIImage(cvPixelBuffer: pb), found)
    }

    // MARK: 下ごしらえ

    private static func downscaled(_ image: CIImage) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard long > longSide else { return image }
        let s = longSide / long
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
    }

    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    /// 大きさと並びを決めた箱を、使い回しの置き場から 1 つ取る（大きさが変わったら置き場を作り直す）。
    /// limit 枚より多くは作らない（足りなければ nil。そのコマは捨てる）
    private static func pooledBuffer(_ pool: inout CVPixelBufferPool?, _ poolSize: inout CGSize, size: CGSize,
                                     format: OSType, limit: Int) -> CVPixelBuffer? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let rounded = CGSize(width: width, height: height)
        if pool == nil || poolSize != rounded {
            pool = PixelPool.make(width: width, height: height, format: format)
            poolSize = rounded
        }
        guard let pool else { return nil }
        return PixelPool.buffer(from: pool, limit: limit)
    }
}

/// 画素の箱の置き場。置いておく数を少なくし（使わない箱は 0.5 秒で手放す）、作る数にも上限をつける
enum PixelPool {
    static func make(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 1,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0.5,
        ]
        var attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        // YUV の箱は色の決まりを付けておく（描くときと読むときで同じ変換になるように）
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            attrs[kCVBufferPropagatedAttachmentsKey as String] = [
                kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            ]
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    /// 置き場の箱が limit 枚に達していたら、新しく作らず nil を返す
    static func buffer(from pool: CVPixelBufferPool, limit: Int) -> CVPixelBuffer? {
        let aux: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: limit]
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux as CFDictionary, &pb)
        return pb
    }
}
