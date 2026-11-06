@preconcurrency import AVFoundation

/// 効果音。音はすべて自前で合成したもの（Resources/Audio。作り方は Tools/make_audio.py）
/// 音声セッションの種類は変えない。録画中はカメラ（AVCaptureSession）が録音向きに組むので、それに乗る
enum Sound {
    /// 3・2・1 のカウント
    static func tick() { Bank.shared.play("tick", volume: 0.7) }
    static func correct() { Bank.shared.play("correct", volume: 1.0) }
    static func pass() { Bank.shared.play("pass", volume: 0.8) }
    /// カンニング
    static func buzzer() { Bank.shared.play("buzzer", volume: 0.8) }
    /// 時間切れ
    static func finish() { Bank.shared.play("finish", volume: 0.9) }
    /// スタート（カウントダウンのあと）
    static func go() { Bank.shared.play("go", volume: 0.8) }

    /// 先に読み込んでおく（最初の 1 回の遅れをなくす）。アプリの起動時に呼んでおくとよい
    static func prepare() { Bank.shared.prepare() }

    /// ハイライト動画で使う音の場所
    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "wav")
    }

    /// 音ごとに 2 つずつ再生器を持ち、続けて鳴っても前の音を切らない
    private final class Bank: @unchecked Sendable {
        static let shared = Bank()
        private let names = ["tick", "correct", "pass", "buzzer", "finish", "go"]
        private let lock = NSLock()
        private var players: [String: [AVAudioPlayer]] = [:]
        private var next: [String: Int] = [:]
        private var loaded = false

        func prepare() {
            lock.lock()
            defer { lock.unlock() }
            loadIfNeeded()
        }

        func play(_ name: String, volume: Float) {
            lock.lock()
            loadIfNeeded()
            routeToSpeakerIfNeeded()
            guard let list = players[name], !list.isEmpty else {
                lock.unlock()
                return
            }
            let i = next[name, default: 0] % list.count
            next[name] = i + 1
            let player = list[i]
            lock.unlock()
            player.volume = volume
            player.currentTime = 0
            player.play()
        }

        /// 呼ぶときはロックを持っていること
        private func loadIfNeeded() {
            guard !loaded else { return }
            loaded = true
            for name in names {
                guard let url = Sound.url(name) else { continue }
                players[name] = (0..<2).compactMap { _ in
                    guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
                    p.prepareToPlay()
                    return p
                }
            }
        }

        /// 録音向きのセッションでは、音が耳当てのスピーカーから小さく出ることがある。
        /// そのときだけ下のスピーカーに切り替える（イヤホンなどはそのまま）。呼ぶときはロックを持っていること
        private func routeToSpeakerIfNeeded() {
            let session = AVAudioSession.sharedInstance()
            guard session.category == .playAndRecord else { return }
            let onReceiver = session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
            guard onReceiver else { return }
            try? session.overrideOutputAudioPort(.speaker)
        }
    }
}
