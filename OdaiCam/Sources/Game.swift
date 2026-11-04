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
    var deck = Deck.builtIn[0]
    var roundLength = 60.0
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
    /// 見え方しばり。当てる人はカメラ越しのしばられた画面だけで当てる
    var effectsOn = true
    /// nil ならおまかせ（お題ごとにくじ）
    var fixedEffect: Effect?
    /// 内側のカメラで当てる人を見張る（顔を上げて本人を見たら減点）
    var cheatGuard = true
    private(set) var cheats = 0
    /// 直前にカンニングした時刻（画面に「カンニング！」を一瞬出す）
    private(set) var lastCheat: Date?

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
        lastCheat = nil
        lastAnswer = nil
        lastAnswerAt = nil
        isNewBest = false
        highlightURL = nil
        highlightError = nil
        recordingStart = nil
        queue = deck.prompts.shuffled()
        startRecording?()
        running = Task {
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                tick.impactOccurred()
                Sound.tick()
                try? await Task.sleep(for: .seconds(1))
            }
            phase = .playing
            if cheatGuard { onWatch?(true) }
            nextPrompt()
            let end = ProcessInfo.processInfo.systemUptime + roundLength
            while !Task.isCancelled {
                remaining = max(0, end - ProcessInfo.processInfo.systemUptime)
                if remaining <= 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
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

    func cheated() {
        guard phase == .playing else { return }
        cheats += 1
        lastCheat = Date()
        answerFeedback.notificationOccurred(.error)
        Sound.buzzer()
    }

    func updateHeard(_ text: String) {
        if phase == .playing { heard = text }
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
    }

    /// 録画ファイルができたら、ハイライト動画を作る
    func recordingFinished(_ recordings: Camera.Recordings) {
        guard phase == .results else { return }
        guard let url = recordings.raw else {
            highlightError = "録画できませんでした"
            return
        }
        let clips = turns.compactMap { t -> Highlight.Clip? in
            guard let end = t.end, let outcome = t.outcome else { return nil }
            return Highlight.Clip(prompt: t.prompt, outcome: outcome.rawValue, effect: t.effect?.label, start: t.start, end: end)
        }
        building = true
        Task {
            do {
                highlightURL = try await Highlight.make(raw: url, seen: recordings.seen, front: recordings.front, clips: clips)
            } catch {
                highlightError = "ハイライトを作れませんでした: \(error.localizedDescription)"
            }
            building = false
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
        onEffect?(effect, ProcessInfo.processInfo.systemUptime)
        heard = ""
        if voiceJudge { onPrompt?(prompt) }
    }

    /// おまかせなら、直前と同じにならないようにくじで選ぶ
    private func nextEffect() -> Effect? {
        guard effectsOn else { return nil }
        if let fixedEffect { return fixedEffect }
        let last = turns.last?.effect
        return Effect.allCases.filter { $0 != last }.randomElement()
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
        answerFeedback.notificationOccurred(.success)
        Sound.finish()
        onPrompt?(nil)
        onEffect?(nil, 0)
        onWatch?(false)
        stopRecording?()
    }
}
