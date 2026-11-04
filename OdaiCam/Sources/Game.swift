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
    private(set) var highlightURL: URL?
    private(set) var highlightError: String?
    private(set) var building = false

    var current: Turn? { phase == .playing ? turns.last : nil }
    var score: Int { turns.filter { $0.outcome == .correct }.count }

    @ObservationIgnored var startRecording: (() -> Void)?
    @ObservationIgnored var stopRecording: (() -> Void)?
    @ObservationIgnored private var recordingStart: TimeInterval?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private let tick = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let answerFeedback = UINotificationFeedbackGenerator()

    func startRound() {
        guard phase == .menu || phase == .results else { return }
        turns = []
        lastAnswer = nil
        highlightURL = nil
        highlightError = nil
        recordingStart = nil
        queue = deck.prompts.shuffled()
        startRecording?()
        running = Task {
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                tick.impactOccurred()
                try? await Task.sleep(for: .seconds(1))
            }
            phase = .playing
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

    func answer(_ outcome: Outcome) {
        guard phase == .playing, var turn = turns.popLast() else { return }
        turn.end = now
        turn.outcome = outcome
        turns.append(turn)
        lastAnswer = (turn.prompt, outcome)
        answerFeedback.notificationOccurred(outcome == .correct ? .success : .warning)
        nextPrompt()
    }

    func backToMenu() {
        running?.cancel()
        stopRecording?()
        phase = .menu
    }

    /// 録画ファイルができたら、ハイライト動画を作る
    func recordingFinished(_ url: URL?) {
        guard phase == .results else { return }
        guard let url else {
            highlightError = "録画できませんでした"
            return
        }
        let clips = turns.compactMap { t -> Highlight.Clip? in
            guard let end = t.end, let outcome = t.outcome else { return nil }
            return Highlight.Clip(prompt: t.prompt, outcome: outcome.rawValue, start: t.start, end: end)
        }
        building = true
        Task {
            do {
                highlightURL = try await Highlight.make(from: url, clips: clips)
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
        turns.append(Turn(prompt: queue.removeFirst(), start: now))
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
        phase = .results
        answerFeedback.notificationOccurred(.success)
        stopRecording?()
    }
}
