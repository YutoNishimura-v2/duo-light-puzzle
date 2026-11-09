import Foundation
import Observation
import UIKit

/// 1 ラウンドの流れ。演じる人（外側）と当てる人（内側）が同じものを読む
@MainActor
@Observable
final class Game {
    enum Phase: Equatable {
        /// 山札と時間を選ぶ
        case menu
        /// 録画を始めてカウントダウン
        case countdown(Int)
        case playing
        /// 時間切れ。ハイライト動画を作っている／できた
        case results
    }

    enum Outcome: String {
        case correct = "○"
        case pass = "パス"
    }

    struct Turn: Identifiable {
        let id = UUID()
        let prompt: String
        /// 当てる人に見せたしばり（なしなら nil）
        let effect: Effect?
        /// 録画の頭からの秒数
        let start: TimeInterval
        var end: TimeInterval?
        var outcome: Outcome?
    }

    private(set) var phase = Phase.menu
    // 最初に開いたときは「動物」・60 秒・しばりなし（effectsOn = false）。主役は人そのもの、しばりはおまけ
    var deck = Deck.defaultForDevice
    var roundLength = 60.0
    /// 直前のラウンドの実際の長さ（試験で短くしたときもその秒数。結果と種明かしの札に出す）
    private(set) var playedLength = 60.0
    private(set) var turns: [Turn] = []
    private(set) var remaining = 0.0
    /// 直前の答え（当てる人に一瞬だけ見せる）
    private(set) var lastAnswer: (prompt: String, outcome: Outcome)?
    /// 正解・パスで画面全体を一瞬光らせる
    private(set) var lastAnswerAt: Date?
    /// 自己ベストを更新したか（結果で紙吹雪）
    private(set) var isNewBest = false
    var best: Int { UserDefaults.standard.integer(forKey: "bestScore") }
    private(set) var highlightURL: URL?
    private(set) var highlightError: String?
    private(set) var building = false
    /// 声で自動判定する（当てる人の声を聞き取る）
    var voiceJudge = true
    /// 聞き取った言葉（当てる人に小さく見せる）
    private(set) var heard = ""
    /// しばりが演じる人を 1 秒以上見つけられていない（両方の画面に「枠に入って」と出す）
    private(set) var actorMissing = false
    /// 見え方しばり（おまけ）。オンのとき、当てる人はカメラ越しのしばられた画面だけで当てる
    /// 最後に選んだモードを覚えておき、次に開いたときの最初の設定にする（どのモードでも最初の設定にできる）。
    /// 試験（偽カメラ）では覚えたものを使わず、いつもしばりなしから始める
    var effectsOn = Game.savedMode.on {
        didSet { saveMode() }
    }
    /// nil ならおまかせ（お題ごとにくじ）
    var fixedEffect: Effect? = Game.savedMode.effect {
        didSet { saveMode() }
    }

    /// 初めて開いたとき（まだモードを選んでいない）の最初の設定。
    /// 主役のモードは「おまかせ」（本人が 2026-11-08 に確定）。
    /// 変えるときはここだけ差し替える（しばりなし＝(false, nil)、着ぐるみ＝(true, .costume) など）
    static let firstRunMode: (on: Bool, effect: Effect?) = (true, nil)

    private static var savedMode: (on: Bool, effect: Effect?) {
        // 試験（偽カメラ）はいつもしばりなしから始める（UI テストはしばりなしを先頭として順に押す）
        if FakeCamera.isOn { return (false, nil) }
        // 画面写真（-shot）は、いつも初めて開いたときの最初の設定で撮る（前の写真の home-bg の「宇宙」が残っていた）
        if Shot.name != nil { return firstRunMode }
        guard let raw = UserDefaults.standard.string(forKey: "mode") else { return firstRunMode }
        if raw == "none" { return (false, nil) }
        if raw == "random" { return (true, nil) }
        return Effect(rawValue: raw).map { (true, $0) } ?? (false, nil)
    }

    private func saveMode() {
        guard !FakeCamera.isOn, Shot.name == nil else { return }
        let raw = !effectsOn ? "none" : (fixedEffect?.rawValue ?? "random")
        UserDefaults.standard.set(raw, forKey: "mode")
    }
    /// 内側のカメラで当てる人を見張る（顔を上げて本人を見たら減点）
    var cheatGuard = true
    /// 減点したカンニングの数（1 回目の注意は入らない）
    private(set) var cheats = 0
    /// 注意だけで済ませたカンニングの数（ラウンドの 1 回目）
    private(set) var cheatWarnings = 0
    /// 直前にカンニングした時刻（画面に「カンニング！」を一瞬出す）。注意のときも入る
    private(set) var lastCheat: Date?
    /// 直前のカンニングが注意だけ（減点なし）だったか。画面の文言を変えるのに使う
    private(set) var lastCheatWasWarning = false
    /// 1 回見上げて減点は 1 回まで（見張り側でも止めているが、念のためここでも間をあける）
    static let cheatCooldown: TimeInterval = 3

    var current: Turn? { phase == .playing ? turns.last : nil }
    var correct: Int { turns.filter { $0.outcome == .correct }.count }
    /// 正解の数からカンニングの数を引く
    var score: Int { max(0, correct - cheats) }

    @ObservationIgnored var startRecording: (() -> Void)?
    @ObservationIgnored var stopRecording: (() -> Void)?
    /// 新しいお題になった（聞き取りをやり直す）。nil でラウンド終わり
    @ObservationIgnored var onPrompt: ((String?) -> Void)?
    /// いまのしばりが変わった（しばりの処理に渡す）。nil でしばりなし
    @ObservationIgnored var onEffect: ((Effect?, TimeInterval) -> Void)?
    /// 見張りを始める・止める
    @ObservationIgnored var onWatch: ((Bool) -> Void)?
    @ObservationIgnored private var recordingStart: TimeInterval?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private let tick = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let answerFeedback = UINotificationFeedbackGenerator()

    func startRound() {
        guard phase == .menu || phase == .results else { return }
        turns = []
        cheats = 0
        cheatWarnings = 0
        lastCheat = nil
        lastCheatWasWarning = false
        lastAnswer = nil
        lastAnswerAt = nil
        isNewBest = false
        // 前のラウンドの種明かし作りは止める（新しいラウンドに古い動画が出ないように。メモリも手放す）
        generation += 1
        demoRound += 1
        buildTask?.cancel()
        buildTask = nil
        deadline?.cancel()
        deadline = nil
        rebuild = nil
        building = false
        highlightURL = nil
        highlightError = nil
        recordingStart = nil
        EffectEngine.seenLog.reset()
        queue = deck.prompts.shuffled()
        CrashLog.mark("ラウンド開始（\(deck.title)・\(Int(roundLength)) 秒・しばり \(effectsOn ? (fixedEffect?.label ?? "おまかせ") : "なし")）")
        startRecording?()
        running = Task {
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                tick.impactOccurred()
                Sound.tick()
                try? await Task.sleep(for: .seconds(1))
                // カウントダウン中に「やめる」を押したら、プレイに進まない
                if Task.isCancelled { return }
            }
            phase = .playing
            Sound.go()
            CrashLog.mark("プレイ開始")
            EffectEngine.perfLog.reset()
            if cheatGuard { onWatch?(true) }
            nextPrompt()
            // 試験用：起動引数 -testRoundSeconds 8 で短くする
            let test = UserDefaults.standard.double(forKey: "testRoundSeconds")
            playedLength = test > 0 ? test : roundLength
            let end = ProcessInfo.processInfo.systemUptime + playedLength
            while !Task.isCancelled {
                remaining = max(0, end - ProcessInfo.processInfo.systemUptime)
                if remaining <= 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // 途中でやめたとき（backToMenu）は結果の画面に進まない
            if Task.isCancelled { return }
            finishRound()
        }
    }

    func recordingStarted(at t: TimeInterval) {
        recordingStart = t
    }

    /// 聞き取りから。いまのお題と同じときだけ正解にする
    func heardAnswer(for prompt: String) {
        guard phase == .playing, current?.prompt == prompt else { return }
        answer(.correct)
    }

    /// 見張りから。ラウンドの 1 回目は注意だけ、2 回目から 1 点引く
    func cheated() {
        guard phase == .playing else { return }
        let date = Date()
        if let lastCheat, date.timeIntervalSince(lastCheat) < Self.cheatCooldown { return }
        if cheatWarnings == 0 {
            cheatWarnings += 1
            lastCheatWasWarning = true
            answerFeedback.notificationOccurred(.warning)
        } else {
            cheats += 1
            lastCheatWasWarning = false
            answerFeedback.notificationOccurred(.error)
        }
        lastCheat = date
        CrashLog.mark(lastCheatWasWarning ? "カンニング（注意）" : "カンニング（−1）")
        Sound.buzzer()
    }

    func updateHeard(_ text: String) {
        if phase == .playing { heard = text }
    }

    /// しばりの処理から、演じる人が見えなくなった・また見えたことを受け取る
    func updateActorMissing(_ missing: Bool) {
        actorMissing = missing && phase == .playing && current?.effect != nil
    }

    func answer(_ outcome: Outcome) {
        guard phase == .playing, var turn = turns.popLast() else { return }
        turn.end = now
        turn.outcome = outcome
        turns.append(turn)
        lastAnswer = (turn.prompt, outcome)
        lastAnswerAt = Date()
        answerFeedback.notificationOccurred(outcome == .correct ? .success : .warning)
        if outcome == .correct { Sound.correct() } else { Sound.pass() }
        nextPrompt()
    }

    func backToMenu() {
        running?.cancel()
        onPrompt?(nil)
        onEffect?(nil, 0)
        onWatch?(false)
        stopRecording?()
        phase = .menu
        generation += 1
        buildTask?.cancel()
        buildTask = nil
        deadline?.cancel()
        deadline = nil
        building = false
    }

    /// 録画ファイルができたら、ハイライト動画を作る
    func recordingFinished(_ recordings: Camera.Recordings) {
        CrashLog.mark("録画を受け取った（元 \(recordings.raw != nil ? "あり" : "なし")・見えていた画面 \(recordings.seen != nil ? "あり" : "なし")・内カメ \(recordings.front != nil ? "あり" : "なし")）")
        guard phase == .results else {
            CrashLog.mark("録画を受け取ったが結果の画面ではないので使わない")
            return
        }
        guard highlightURL == nil, !building, rebuild == nil else { return }
        guard let url = recordings.raw else {
            deadline?.cancel()
            highlightError = String(localized: "録画できませんでした")
            return
        }
        // 種明かし動画の文字は山札の言葉で書く
        let language = deck.language
        // しばりの画面に人が映っていたか。録画の秒を、記録と同じ時計の秒に直して聞く（しばりなしは全部映っていたことに）
        let base = recordingStart
        func quality(_ t: Turn, _ from: TimeInterval, _ to: TimeInterval) -> SeenQuality {
            guard t.effect != nil, let base else { return .full }
            return EffectEngine.seenLog.quality(from: base + from, to: base + to)
        }
        let clips = turns.compactMap { t -> Highlight.Clip? in
            guard let end = t.end, let outcome = t.outcome else { return nil }
            // ハイライトと同じ区間：見えていた画面は実際の演技の頭から、つかみは答える直前の 1 秒
            let to = end + Highlight.after
            let from = max(t.start, to - Highlight.realLength)
            let seen = quality(t, from, min(from + Highlight.seenLength, to))
            let hook = quality(t, max(t.start, end - Highlight.hookLength), end)
            // 調べもの：各ラウンドの 1 問目が「人が映っていない」で外れていたので、お題ごとの映り方を残す
            if let e = t.effect {
                let first = EffectEngine.seenLog.firstTime.map { String(format: "%.2f", $0 - (base ?? 0)) } ?? "なし"
                CrashLog.mark(String(format: "映り方：%@ %@ 区間 %.2f〜%.2f 秒 映った割合 %.2f 途切れ最長 %.2f 秒（記録の最初 %@ 秒）",
                                     t.prompt, e.name, from, min(from + Highlight.seenLength, to),
                                     seen.visibleFraction, seen.longestEmpty, first))
            }
            return Highlight.Clip(prompt: t.prompt, outcome: outcome.rawValue, effect: t.effect?.label(language: language),
                                  start: t.start, end: end,
                                  seenQuality: seen, hookQuality: hook)
        }
        rebuild = { [weak self] overlay in
            self?.buildHighlight(url: url, recordings: recordings, clips: clips, language: language, overlay: overlay)
        }
        buildHighlight(url: url, recordings: recordings, clips: clips, language: language)
    }

    /// 種明かし動画を作り直す（結果の画面の「作り直す」から）
    func rebuildHighlight() {
        guard !building, highlightURL == nil else { return }
        highlightError = nil
        guard let rebuild else {
            // 録画そのものが届いていない。作り直せないことを伝える
            highlightError = String(localized: "録画を受け取れませんでした。もう一回遊んでください")
            return
        }
        // 2 回目からは帯の重ね書きを省き、早く出す
        rebuild(false)
    }

    @ObservationIgnored private var rebuild: ((Bool) -> Void)?
    /// いまのラウンドの番号。古いラウンドの書き出しが、あとから新しいラウンドの結果を書き換えないように
    @ObservationIgnored private var generation = 0
    /// デモでラウンドごとにしばりの順をずらす
    @ObservationIgnored private var demoRound = -1
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    /// 結果の画面で待たせる上限（録画の後片付けから書き出しまで全部で）。
    /// 実機は 30 秒。シミュレータは 1080x1920 の書き出しがとても遅いので長め
    static var highlightLimit: TimeInterval {
        #if targetEnvironment(simulator)
        return 200
        #else
        return 30
        #endif
    }

    /// ラウンドが終わったら締め切りを決める。録画が届かない・書き出しが止まる、どちらでも上限で打ち切って伝える
    private func startDeadline() {
        deadline?.cancel()
        let gen = generation
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.highlightLimit))
            guard !Task.isCancelled, let self, gen == self.generation,
                  self.highlightURL == nil, self.highlightError == nil else { return }
            CrashLog.mark("種明かし：\(Int(Self.highlightLimit)) 秒で終わらず打ち切り（録画 \(self.rebuild != nil ? "あり" : "届かず")）")
            self.buildTask?.cancel()
            self.buildTask = nil
            self.building = false
            self.highlightError = String(localized: "時間がかかりすぎたので止めました")
        }
    }

    private func buildHighlight(url: URL, recordings: Camera.Recordings, clips: [Highlight.Clip], language: String, overlay: Bool = true) {
        building = true
        let gen = generation
        let started = Date()
        CrashLog.mark("種明かし：作り始め（帯 \(overlay && !Self.fastExport ? "あり" : "なし")）")
        // 作り直しのときも、そこから上限まで
        if overlay == false { startDeadline() }
        buildTask = Task {
            do {
                let made = try await Self.makeWithRetry {
                    try await Highlight.make(raw: url, seen: recordings.seen, front: recordings.front, clips: clips, score: score,
                                             roundSeconds: Int(playedLength.rounded()), overlay: overlay && !Self.fastExport, language: language)
                }
                guard gen == generation, !Task.isCancelled else { return }
                highlightURL = made
                deadline?.cancel()
                // デモ（CI）では、できた動画を Documents にも残す（一時フォルダは試験の終わりに消えて、取り出せなかった）
                if FakeCamera.isDemo, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let keep = docs.appendingPathComponent("highlight-demo-\(Int(Date().timeIntervalSince1970)).mp4")
                    try? FileManager.default.copyItem(at: made, to: keep)
                }
                CrashLog.mark("種明かし：できた（\(Int(Date().timeIntervalSince(started))) 秒）")
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                highlightError = String(localized: "ハイライトを作れませんでした: \(Self.describe(error))")
                deadline?.cancel()
                CrashLog.mark("ハイライト失敗：\(Self.describe(error))")
            }
            building = false
        }
    }

    /// 試験用：起動引数 -testFastExport YES で、帯の重ね書き（2 回目の書き出し）を省く。
    /// シミュレータでは 1080x1920 の重ね書きがとても遅く、8 ラウンドの UI テストが時間切れになったため
    static let fastExport = UserDefaults.standard.bool(forKey: "testFastExport")

    /// ラウンドの直後は、しばりの処理や録画の後片付けで映像の読み込み口が埋まっていて、
    /// 1 回目の書き出しだけ「Cannot Decode（-11821）」で落ちることがある（デモで毎回起きた。すぐ作り直すと通る）。
    /// 少し待って 2 回まで作り直す
    private static func makeWithRetry(_ make: () async throws -> URL) async throws -> URL {
        var last: Error?
        // 作り直しは 1 回まで（何度も重ねると、上限の 30 秒を食いつぶすため）
        for attempt in 0..<2 {
            if attempt > 0 {
                guard !Task.isCancelled else { break }
                CrashLog.mark("ハイライト：作り直し \(attempt) 回目（\(describe(last!))）")
                try? await Task.sleep(for: .milliseconds(700))
            }
            do { return try await make() } catch { last = error }
        }
        throw last!
    }

    /// 失敗の理由を、元の原因の番号まで並べる（AVFoundation の文言だけでは分からないため）
    private static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var e: NSError? = error as NSError
        while let n = e, parts.count < 4 {
            parts.append("\(n.localizedDescription)（\(n.domain) \(n.code)）")
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ← ")
    }

    /// 画面の確認用（起動引数 -shot）。カメラなしで各画面の状態を作る
    func loadPreview(_ shot: String) {
        // 画面写真用のお題。英語の端末では英語の見本にする
        let en = Deck.deviceLanguage != "ja"
        let names = en ? ["Gorilla", "Penguin", "Kangaroo", "Flamingo", "Sloth"]
                       : ["ゴリラ", "ペンギン", "カンガルー", "フラミンゴ", "ナマケモノ"]
        let sample: [(String, Effect?, Outcome)] = [
            (names[0], nil, .correct), (names[1], .space, .correct), (names[2], nil, .pass),
            (names[3], .stage, .correct), (names[4], .silhouette, .correct),
        ]
        turns = sample.enumerated().map { i, t in
            Turn(prompt: t.0, effect: t.1, start: Double(i) * 8, end: Double(i) * 8 + 6, outcome: t.2)
        }
        remaining = 42
        heard = en ? "gorilla" : "ごりら"
        switch shot {
        case "countdown": phase = .countdown(3)
        case "play":
            // 最初の設定（firstRunMode、おまかせ）のまま。おまかせなら姿のしばりがかかったお題を見せる
            let shown: Effect? = effectsOn ? (fixedEffect ?? .costume) : nil
            turns.append(Turn(prompt: en ? "Koala" : "コアラ", effect: shown, start: 40))
            phase = .playing
        case "home-bg":
            // 背景を宇宙に変えたホーム
            effectsOn = true
            fixedEffect = .space
            phase = .menu
        case "play-bg":
            effectsOn = true
            fixedEffect = .space
            turns.append(Turn(prompt: en ? "Koala" : "コアラ", effect: .space, start: 40))
            phase = .playing
        case "results":
            cheatWarnings = 1
            cheats = 1
            isNewBest = true
            phase = .results
        default: phase = .menu
        }
    }

    private var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime - (recordingStart ?? ProcessInfo.processInfo.systemUptime)
    }

    private func nextPrompt() {
        if queue.isEmpty { queue = deck.prompts.shuffled() }
        let prompt = queue.removeFirst()
        let effect = nextEffect()
        turns.append(Turn(prompt: prompt, effect: effect, start: now))
        CrashLog.mark("お題 \(turns.count)：しばり \(effect?.label ?? "なし")")
        onEffect?(effect, ProcessInfo.processInfo.systemUptime)
        heard = ""
        if voiceJudge { onPrompt?(prompt) }
    }

    /// おまかせの中心：姿を変えるしばり（着ぐるみ・影絵・モザイク・棒人間）。ほかのしばりより 3 倍出やすくする
    static let figureEffects: [Effect] = [.costume, .silhouette, .mosaic, .stick]

    /// おまかせなら、直前と同じにならないようにくじで選ぶ。
    /// デモ（CI）では、ラウンドの 1 問目から姿を変えるしばりを順に出す（種明かし動画に着ぐるみなどが必ず入るように）
    private func nextEffect() -> Effect? {
        guard effectsOn else { return nil }
        if let fixedEffect { return fixedEffect }
        let last = turns.last?.effect
        if FakeCamera.isDemo {
            let order = Self.figureEffects
            return order[(turns.count + demoRound) % order.count]
        }
        let pool = Effect.allCases.flatMap { Self.figureEffects.contains($0) ? [$0, $0, $0] : [$0] }
        return pool.filter { $0 != last }.randomElement()
    }

    private func finishRound() {
        // 答えずに終わったお題は、最後まで演じた分をパス扱いで残す
        if var last = turns.popLast() {
            if last.outcome == nil {
                last.end = now
                last.outcome = .pass
            }
            turns.append(last)
        }
        if score > best {
            UserDefaults.standard.set(score, forKey: "bestScore")
            isNewBest = score > 0
        }
        phase = .results
        CrashLog.mark("ラウンド終了")
        // 1 コマの処理時間・熱・落ちたコマを残す（設定の「診断」に出る。本人が遊ぶだけで実機の数字が残る）
        if let perf = EffectEngine.perfLog.summary() {
            PerfLog.save(perf)
            CrashLog.mark("重さ：" + perf.replacingOccurrences(of: "\n", with: " ｜ "))
        }
        answerFeedback.notificationOccurred(.success)
        Sound.finish()
        onPrompt?(nil)
        onEffect?(nil, 0)
        onWatch?(false)
        startDeadline()
        stopRecording?()
    }
}
