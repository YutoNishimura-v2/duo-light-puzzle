@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision
import VideoToolbox

/// 当てる人に見せる映りのしばり（おまけ。基本はしばりなしで、人そのものを見せる）。
/// 並びはホームのモード列の順。背景を変えるもの → 姿を変えるもの
enum Effect: String, CaseIterable, Identifiable, Sendable {
    // 姿を変えるもの（棒人間・モザイク・着ぐるみ・影絵）を先に、背景 → そのほかの順
    case stick, mosaic, costume, silhouette
    case space, sea, classroom, stage
    case delay, peephole

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
        case .costume: "着ぐるみ"
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

/// モザイクの粗さ（遊ぶ前に選ぶ）
enum MosaicLevel: String, CaseIterable, Identifiable, Sendable {
    case coarse, normal, fine
    var id: String { rawValue }
    /// 日本語の名前（訳の表の鍵）
    var name: String {
        switch self {
        case .coarse: "粗い"
        case .normal: "ふつう"
        case .fine: "細かい"
        }
    }
    var label: String { NSLocalizedString(name, comment: "モザイクの粗さ") }
    /// 1 マスの大きさ（画面の幅に対する割合）
    var blockFraction: CGFloat {
        switch self {
        // いちばん粗くても人の形が分かる大きさにする（0.16 は色の四角が並ぶだけで、壊れた画面に見えた）
        case .coarse: 0.085
        case .normal: 0.06
        case .fine: 0.035
        }
    }
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
    /// モザイクの粗さ（ホームで選ぶ。main で書き、しばりのキューで読む）
    nonisolated(unsafe) static var mosaicLevel: MosaicLevel =
        MosaicLevel(rawValue: UserDefaults.standard.string(forKey: "mosaicLevel") ?? "") ?? .normal
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

    /// 見比べ用：1 枚の絵にしばりをかけて返す（nil はしばりなし）。どのキューから呼んでもよいが、同時には呼ばない
    func still(_ effect: Effect?, source: CVPixelBuffer, frameTime: TimeInterval) -> CGImage? {
        let input = Self.downscaled(CIImage(cvPixelBuffer: source))
        var output = input
        if let effect {
            smoothedJoints = [:]
            output = render(effect, input: input, source: source, now: frameTime, elapsed: 0, frameTime: frameTime).image
        }
        return context.createCGImage(output.cropped(to: input.extent), from: input.extent)
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
        case .costume:
            let suit = costume(source: source, input: input, now: now, frameTime: frameTime)
            return (suit.image, suit.found)
        default:
            return (plain(effect, input: input, now: now, elapsed: elapsed, black: black), true)
        }
    }

    private func plain(_ effect: Effect, input: CIImage, now: TimeInterval, elapsed: TimeInterval, black: CIImage) -> CIImage {
        switch effect {
        case .stick, .silhouette, .space, .sea, .classroom, .stage, .costume:
            return black
        case .mosaic:
            // 粗さは遊ぶ前に 3 段から選ぶ（ホームのモザイクの下の札）。お題ごとに粗く始まり、少しだけ細かくなる
            let coarse = Self.mosaicLevel.blockFraction * input.extent.width
            let progress = min(max(elapsed / 25, 0), 1)
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(max(coarse * (1 - 0.35 * progress), 4))
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
            // 切り抜きに失敗したコマは、0.6 秒までは直前の形を使い続ける（影絵や着ぐるみが一瞬真っ黒・空にならないように）
            if found {
                lastGoodMask = maskBuffer
                lastGoodMaskTime = now
            } else if let good = lastGoodMask, now - lastGoodMaskTime < 0.6 {
                maskBuffer = good
                found = true
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

    /// 直前にうまく取れた人の型抜き（切り抜きに失敗したコマの代わり）
    private var lastGoodMask: CVPixelBuffer?
    private var lastGoodMaskTime: TimeInterval = 0

    typealias Joints = [VNHumanBodyPoseObservation.JointName: CGPoint]
    /// 前のコマの関節（なめらかに動かすため、新しい位置と混ぜる）
    private var smoothedJoints: Joints = [:]

    /// 人の関節（0〜1、左下が原点）。found は関節が十分に見つかったか。1 人目だけをなめらかにする
    private func bodyJoints(source: CVPixelBuffer, now: TimeInterval, frameTime: TimeInterval) -> (bodies: [Joints], found: Bool) {
        let demo = FakeCamera.isDemo
        var found = false
        var bodies: [Joints] = []
        if Self.usesVision, !(demo && now < bodyRetryAt) {
            let handler = VNImageRequestHandler(cvPixelBuffer: source)
            try? handler.perform([bodyRequest])
            for body in bodyRequest.results ?? [] {
                guard let points = try? body.recognizedPoints(.all) else { continue }
                var sure: Joints = [:]
                for (name, pt) in points where pt.confidence > 0.2 { sure[name] = pt.location }
                if sure.count >= Self.minJoints { found = true }
                bodies.append(sure)
            }
            if demo, !found { bodyRetryAt = now + Self.demoVisionRetry }
        }
        if !found, demo {
            bodies = [DemoActor.joints(at: frameTime)]
            found = true
        }
        // 震えを抑える：前のコマの位置と半々に混ぜる（大きく動いたときはそのまま）
        if var first = bodies.first {
            for (name, p) in first {
                if let q = smoothedJoints[name], hypot(p.x - q.x, p.y - q.y) < 0.08 {
                    first[name] = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                }
            }
            smoothedJoints = first
            bodies[0] = first
        }
        return (bodies, found)
    }

    /// 骨組みの人形（棒人間）と着ぐるみの描き方
    enum FigureStyle { case stick, costume }

    /// 関節から人形を描く。ctx は左下が原点、w×h の大きさ
    static func drawFigure(_ points: Joints, style: FigureStyle, in ctx: CGContext, w: CGFloat, h: CGFloat) {
        func p(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let pt = points[name] else { return nil }
            return CGPoint(x: pt.x * w, y: pt.y * h)
        }
        func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
            guard let a, let b else { return a ?? b }
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let neck = p(.neck) ?? mid(p(.leftShoulder), p(.rightShoulder))
        let root = p(.root) ?? mid(p(.leftHip), p(.rightHip))
        // 体の大きさの目安（肩幅か、首から腰まで）
        var unit = w / 10
        if let l = p(.leftShoulder), let r = p(.rightShoulder) { unit = max(hypot(l.x - r.x, l.y - r.y), w / 20) }
        else if let neck, let root { unit = max(hypot(neck.x - root.x, neck.y - root.y) * 0.6, w / 20) }
        // 頭の上の向き（首→鼻。なければ真上）
        var up = CGVector(dx: 0, dy: 1)
        if let neck, let nose = p(.nose) {
            let d = hypot(nose.x - neck.x, nose.y - neck.y)
            if d > 1 { up = CGVector(dx: (nose.x - neck.x) / d, dy: (nose.y - neck.y) / d) }
        }
        let headR = style == .stick ? unit * 0.42 : unit * 0.62
        let headCenter: CGPoint? = neck.map { CGPoint(x: $0.x + up.dx * headR * 1.15, y: $0.y + up.dy * headR * 1.15) }

        let limbs: [[VNHumanBodyPoseObservation.JointName]] = [
            [.leftShoulder, .leftElbow, .leftWrist], [.rightShoulder, .rightElbow, .rightWrist],
            [.leftHip, .leftKnee, .leftAnkle], [.rightHip, .rightKnee, .rightAnkle],
        ]
        func strokeLimbs(width: CGFloat, color: CGColor) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            for limb in limbs {
                let pts = limb.compactMap { p($0) }
                guard pts.count >= 2 else { continue }
                ctx.move(to: pts[0])
                for q in pts.dropFirst() { ctx.addLine(to: q) }
                ctx.strokePath()
            }
            // 肩・腰から胴へつなぐ
            if let neck {
                for s in [p(.leftShoulder), p(.rightShoulder)].compactMap({ $0 }) { ctx.move(to: neck); ctx.addLine(to: s) }
            }
            if let root {
                for s in [p(.leftHip), p(.rightHip)].compactMap({ $0 }) { ctx.move(to: root); ctx.addLine(to: s) }
            }
            ctx.strokePath()
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch style {
        case .stick:
            // 黄色の太い線に濃い縁。胴はカプセル、関節は丸、頭は顔つき
            let yellow = UIColor(red: 1, green: 0.84, blue: 0.3, alpha: 1).cgColor
            let edge = UIColor(red: 0.55, green: 0.3, blue: 0.05, alpha: 1).cgColor
            let line = max(unit * 0.2, 6)
            // 足元の影
            if let la = p(.leftAnkle) ?? p(.rightAnkle) {
                let foot = mid(p(.leftAnkle), p(.rightAnkle)) ?? la
                ctx.setFillColor(UIColor(white: 0, alpha: 0.35).cgColor)
                ctx.fillEllipse(in: CGRect(x: foot.x - unit * 0.9, y: foot.y - unit * 0.18, width: unit * 1.8, height: unit * 0.3))
            }
            strokeLimbs(width: line * 1.45, color: edge)
            if let neck, let root {
                ctx.setStrokeColor(edge); ctx.setLineWidth(line * 2.4)
                ctx.move(to: neck); ctx.addLine(to: root); ctx.strokePath()
                ctx.setStrokeColor(yellow); ctx.setLineWidth(line * 1.95)
                ctx.move(to: neck); ctx.addLine(to: root); ctx.strokePath()
            }
            strokeLimbs(width: line, color: yellow)
            // 関節の丸と、手足の先の大きめの丸
            ctx.setFillColor(edge)
            for name: VNHumanBodyPoseObservation.JointName in [.leftElbow, .rightElbow, .leftKnee, .rightKnee] {
                if let q = p(name) { ctx.fillEllipse(in: CGRect(x: q.x - line * 0.42, y: q.y - line * 0.42, width: line * 0.84, height: line * 0.84)) }
            }
            for name: VNHumanBodyPoseObservation.JointName in [.leftWrist, .rightWrist, .leftAnkle, .rightAnkle] {
                guard let q = p(name) else { continue }
                let r = line * 0.85
                ctx.setFillColor(edge); ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2))
                ctx.setFillColor(yellow); ctx.fillEllipse(in: CGRect(x: q.x - r * 0.72, y: q.y - r * 0.72, width: r * 1.44, height: r * 1.44))
            }
            if let c = headCenter {
                drawHead(at: c, r: headR, up: up, fill: yellow, edge: edge, line: line * 0.5, in: ctx, ears: false)
            }
        case .costume:
            // オリジナルのクマの着ぐるみ：太い茶色の手足、白いお腹、大きな頭と耳
            let fur = UIColor(red: 0.55, green: 0.36, blue: 0.22, alpha: 1).cgColor
            let furDark = UIColor(red: 0.36, green: 0.22, blue: 0.13, alpha: 1).cgColor
            let cream = UIColor(red: 0.98, green: 0.9, blue: 0.76, alpha: 1).cgColor
            let line = max(unit * 0.55, 14)
            strokeLimbs(width: line * 1.12, color: furDark)
            strokeLimbs(width: line, color: fur)
            if let neck, let root {
                let c = mid(neck, root)!
                let len = hypot(neck.x - root.x, neck.y - root.y)
                let bodyW = max(unit * 1.25, line * 1.6), bodyH = len * 1.35
                let angle = atan2(neck.y - root.y, neck.x - root.x) - .pi / 2
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: angle)
                ctx.setFillColor(furDark)
                ctx.fillEllipse(in: CGRect(x: -bodyW / 2 - 3, y: -bodyH / 2 - 3, width: bodyW + 6, height: bodyH + 6))
                ctx.setFillColor(fur)
                ctx.fillEllipse(in: CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH))
                ctx.setFillColor(cream)
                ctx.fillEllipse(in: CGRect(x: -bodyW * 0.3, y: -bodyH * 0.32, width: bodyW * 0.6, height: bodyH * 0.55))
                ctx.restoreGState()
            }
            // 手足の先はクリーム色の肉球
            for name: VNHumanBodyPoseObservation.JointName in [.leftWrist, .rightWrist, .leftAnkle, .rightAnkle] {
                guard let q = p(name) else { continue }
                let r = line * 0.62
                ctx.setFillColor(furDark); ctx.fillEllipse(in: CGRect(x: q.x - r * 1.1, y: q.y - r * 1.1, width: r * 2.2, height: r * 2.2))
                ctx.setFillColor(cream); ctx.fillEllipse(in: CGRect(x: q.x - r * 0.8, y: q.y - r * 0.8, width: r * 1.6, height: r * 1.6))
            }
            if let c = headCenter {
                drawHead(at: c, r: headR, up: up, fill: fur, edge: furDark, line: 4, in: ctx, ears: true, muzzle: cream)
            }
        }
    }

    /// 顔つきの頭。up の向きに目と口をそろえる
    private static func drawHead(at c: CGPoint, r: CGFloat, up: CGVector, fill: CGColor, edge: CGColor, line: CGFloat,
                                 in ctx: CGContext, ears: Bool, muzzle: CGColor? = nil) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: atan2(up.dy, up.dx) - .pi / 2)
        if ears {
            for side: CGFloat in [-1, 1] {
                let e = CGPoint(x: side * r * 0.72, y: r * 0.72)
                ctx.setFillColor(edge); ctx.fillEllipse(in: CGRect(x: e.x - r * 0.36, y: e.y - r * 0.36, width: r * 0.72, height: r * 0.72))
                ctx.setFillColor(fill); ctx.fillEllipse(in: CGRect(x: e.x - r * 0.3, y: e.y - r * 0.3, width: r * 0.6, height: r * 0.6))
                ctx.setFillColor(UIColor(red: 0.95, green: 0.6, blue: 0.6, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: e.x - r * 0.16, y: e.y - r * 0.16, width: r * 0.32, height: r * 0.32))
            }
        }
        ctx.setFillColor(edge)
        ctx.fillEllipse(in: CGRect(x: -r - line, y: -r - line, width: (r + line) * 2, height: (r + line) * 2))
        ctx.setFillColor(fill)
        ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        if let muzzle {
            ctx.setFillColor(muzzle)
            ctx.fillEllipse(in: CGRect(x: -r * 0.45, y: -r * 0.62, width: r * 0.9, height: r * 0.62))
            ctx.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: -r * 0.13, y: -r * 0.3, width: r * 0.26, height: r * 0.18))
        }
        // 目（白い光つき）
        let eyeY = r * 0.12, eyeX = r * 0.36, eyeR = r * 0.13
        for side: CGFloat in [-1, 1] {
            ctx.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: side * eyeX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2.3))
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: side * eyeX - eyeR * 0.2, y: eyeY + eyeR * 0.6, width: eyeR * 0.7, height: eyeR * 0.7))
        }
        // にっこり口
        ctx.setStrokeColor(UIColor(white: 0.1, alpha: 1).cgColor)
        ctx.setLineWidth(max(r * 0.07, 2))
        ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: 0, y: muzzle == nil ? -r * 0.15 : -r * 0.38), radius: r * 0.28,
                   startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 骨組みの人形を描く。found は関節が十分に見つかったか
    private func stickFigure(source: CVPixelBuffer, size: CGSize, now: TimeInterval,
                             frameTime: TimeInterval) -> (image: CIImage?, found: Bool) {
        let joints = bodyJoints(source: source, now: now, frameTime: frameTime)
        let bodies = joints.bodies, found = joints.found
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
        // 夜空のような濃紺のグラデーションに、床の線
        let colors = [UIColor(red: 0.1, green: 0.12, blue: 0.24, alpha: 1).cgColor,
                      UIColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        }
        for points in bodies {
            Self.drawFigure(points, style: .stick, in: ctx, w: CGFloat(w), h: CGFloat(h))
        }
        ctx.flush()
        return (CIImage(cvPixelBuffer: pb), found)
    }

    /// 着ぐるみ：本物の人を型抜きで塗りつぶし、関節の位置にクマの着ぐるみを描いて重ねる（背景はそのまま）
    private func costume(source: CVPixelBuffer, input: CIImage, now: TimeInterval,
                         frameTime: TimeInterval) -> (image: CIImage, found: Bool) {
        let joints = bodyJoints(source: source, now: now, frameTime: frameTime)
        let size = input.extent.size
        var base = input
        // 人の形を少し太らせた型抜きで、元の人を毛の色で隠す（着ぐるみの下から本人がはみ出さないように）
        if let mask = personMask(source: source, input: input, now: now, frameTime: frameTime).mask {
            let grow = CIFilter.morphologyMaximum()
            grow.inputImage = mask.clampedToExtent()
            grow.radius = Float(max(3, size.width * 0.012))
            let fat = (grow.outputImage ?? mask).applyingGaussianBlur(sigma: 2).cropped(to: input.extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = CIImage(color: CIColor(red: 0.55, green: 0.36, blue: 0.22)).cropped(to: input.extent)
            blend.backgroundImage = input
            blend.maskImage = fat
            base = blend.outputImage ?? input
        }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let pb = Self.pooledBuffer(&stickPool, &stickPoolSize, size: CGSize(width: w, height: h),
                                         format: kCVPixelFormatType_32BGRA, limit: 3) else { return (base, joints.found) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (base, joints.found) }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        for points in joints.bodies {
            Self.drawFigure(points, style: .costume, in: ctx, w: CGFloat(w), h: CGFloat(h))
        }
        ctx.flush()
        let suit = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(translationX: input.extent.minX, y: input.extent.minY))
        return (suit.composited(over: base), joints.found)
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
