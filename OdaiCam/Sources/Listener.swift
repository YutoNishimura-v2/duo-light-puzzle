@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// 当てる人の声を聞き取り、いまのお題を言ったら知らせる。
/// iPhone の音声認識（Speech）を端末の中だけで使う。お題が変わるたびに聞き直す
final class Listener: @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var target: [String] = []
    private var matched = false

    /// 聞き取った言葉（main で呼ぶ）
    var onHeard: (@MainActor (String) -> Void)?
    /// いまのお題を言った（main で呼ぶ）
    var onMatch: (@MainActor (String) -> Void)?

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// 端末の中だけで聞き取れるか。できないときは声の判定を使わない（声を外に送らない）
    var isAvailable: Bool { recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true }

    /// 新しいお題で聞き直す。hints は山札の言葉（聞き取りやすくする）
    func listen(for prompt: String, hints: [String]) {
        stop()
        guard let recognizer, isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = Array(Set(hints + [prompt]))
        request.requiresOnDeviceRecognition = true
        let key = AnswerMatcher.keys(for: prompt)
        lock.withLock {
            self.request = request
            self.target = key
            self.matched = false
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let heard = result.bestTranscription.formattedString
            Task { @MainActor [onHeard] in onHeard?(heard) }
            // 第一候補だけでなく、ほかの候補も見る
            let candidates = result.transcriptions.map(\.formattedString)
            let hit: Bool = lock.withLock {
                guard !matched, AnswerMatcher.matches(candidates, keys: target) else { return false }
                matched = true
                return true
            }
            if hit { Task { @MainActor [onMatch] in onMatch?(prompt) } }
        }
    }

    func stop() {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
        task?.cancel()
        task = nil
    }

    /// カメラのキューから呼ぶ
    func append(_ buffer: CMSampleBuffer) {
        lock.withLock { request }?.appendAudioSampleBuffer(buffer)
    }
}

/// 言い方の揺れ（漢字・カタカナ・ひらがな、空白、記号）をならして比べる
enum AnswerMatcher {
    /// お題の比べ方。かなにそろえたものと、読み（ローマ字）の 2 通り
    static func keys(for prompt: String) -> [String] {
        Array(Set([kana(prompt), reading(prompt)].filter { $0.count >= 2 }))
    }

    static func matches(_ candidates: [String], keys: [String]) -> Bool {
        for c in candidates {
            let forms = [kana(c), reading(c)]
            if keys.contains(where: { key in forms.contains { $0.contains(key) } }) { return true }
        }
        return false
    }

    /// カタカナをひらがなに、英字を小文字にし、空白と記号を除く
    static func kana(_ s: String) -> String {
        let hira = s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s
        return strip(hira.lowercased())
    }

    /// 漢字を含めて読みをローマ字にする（「寿司職人」も「すし職人」も sushishokunin）
    static func reading(_ s: String) -> String {
        let cf = s as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        guard let tokenizer = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWordBoundary,
                                                      Locale(identifier: "ja_JP") as CFLocale) else { return strip(s) }
        var out = ""
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while type.rawValue != 0 {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                out += latin
            } else {
                let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                out += (s as NSString).substring(with: NSRange(location: r.location, length: r.length))
            }
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        // 長音や記号の揺れを消す（「ー」「・」、ローマ字の ^ など）
        let latin = out.applyingTransform(.stripDiacritics, reverse: false) ?? out
        return strip(latin.lowercased())
    }

    private static func strip(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || isKana($0) }.map(Character.init))
            .replacingOccurrences(of: "ー", with: "")
    }

    private static func isKana(_ u: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(Int(u.value))
    }
}
