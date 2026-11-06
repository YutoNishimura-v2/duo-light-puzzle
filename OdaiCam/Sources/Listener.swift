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
    private var target: [AnswerMatcher.Key] = []
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
        let keys = AnswerMatcher.keys(for: prompt)
        lock.withLock {
            self.request = request
            self.target = keys
            self.matched = false
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let heard = result.bestTranscription.formattedString
            Task { @MainActor [onHeard] in onHeard?(heard) }
            // 第一候補だけでなく、ほかの候補も見る。認識の区切り（segments）を単語の切れ目に使う
            let candidates: [[String]] = result.transcriptions.map { t in
                let pieces = t.segments.map(\.substring)
                return pieces.isEmpty ? [t.formattedString] : pieces
            }
            let hit: Bool = lock.withLock {
                guard !self.matched, AnswerMatcher.matches(candidates, keys: self.target) else { return false }
                self.matched = true
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

/// 言ったことがお題と同じかを、単語の切れ目で比べる。
///
/// 1. お題も聞き取りも単語に分け、それぞれの読みをひらがなにする
///    （漢字は CFStringTokenizer の読み（ローマ字）→ ひらがな。「象」も「ぞう」も「ゾウ」も「ぞう」）
/// 2. 伸ばす音をそろえる（「ぞう」「ぞお」「ぞー」→「ぞー」）
/// 3. 聞き取りの単語 1 つ、または続いた単語のまとまりが、お題の読みと同じなら正解。
///    言葉の途中に含まれているだけ（「ぞうきん」の中の「ぞう」）では正解にしない
///
/// 短いお題（読みが 3 文字以下）は、単語のまとまりがぴったり同じときだけ。
/// 長いお題は、小さい「ぁぃぅぇぉ」や伸ばす音の違いを無視し、単語の頭から始まっていれば後ろに何が続いてもよい。
///
/// 例（読みのならし方から追える結果。端末の辞書の切り方で変わることはある）:
/// - お題「ゾウ」（ぞー、短い）
///   - 「ぞう」→ [ぞー] 正解 ／「ゾウだ！」→ [ぞー][だ] 正解 ／「象」→ [ぞー] 正解
///   - 「ぞうきん」→ [ぞーきん] 不正解（単語の途中）／「ぞうさんかな」→ [ぞー][さん][かな] 正解
/// - お題「スキー」（すきー、短い）
///   - 「スキー」正解 ／「好き」→ [すき] 不正解（伸ばす音が違う）
/// - お題「カンガルー」（長い：かんがる）
///   - 「カンガルー」「かんがるう」「カンガルーだよ」正解 ／「ね、カンガルー」→ [ね][かんがる…] 正解
/// - お題「傘をさす」（長い：かさをさす、助詞を落とした かささす も受ける）
///   - 「傘をさす」「傘さす」正解 ／「日傘をさす」→ [ひがさ][を][さす] 不正解（単語の途中から）
/// - お題「DJ」（英字はそのまま dj、短い）→「DJ」正解 ／「DJだ」→ [dj][だ] 正解
enum AnswerMatcher {
    struct Key: Hashable {
        /// ならした読み
        let reading: String
        /// 短いお題。単語のまとまりがぴったり同じときだけ正解
        let short: Bool
    }

    /// これ以下の長さの読みは「短いお題」
    static let shortLength = 3

    /// 落としても意味が通る助詞（「傘をさす」→「傘さす」）
    private static let particles: Set<String> = ["を", "の", "が", "に", "で", "へ", "と", "は"]

    static func keys(for prompt: String) -> [Key] {
        let tokens = words(prompt)
        guard !tokens.isEmpty else { return [] }
        let full = tokens.map(\.reading).joined()
        if light(full).count <= shortLength {
            return [Key(reading: light(full), short: true)]
        }
        var keys: Set<Key> = [Key(reading: strong(full), short: false)]
        let dropped = tokens.filter { !particles.contains($0.surface) }.map(\.reading).joined()
        if dropped != full, strong(dropped).count > shortLength {
            keys.insert(Key(reading: strong(dropped), short: false))
        }
        return Array(keys)
    }

    /// candidates は聞き取りの候補ごとの区切り（認識の segments）。区切りの中もさらに単語に分ける
    static func matches(_ candidates: [[String]], keys: [Key]) -> Bool {
        for pieces in candidates {
            let tokens = pieces.flatMap { words($0).map(\.reading) }
            if keys.contains(where: { matches(tokens, key: $0) }) { return true }
        }
        return false
    }

    /// 区切りのない文字列で比べる（確かめ用）
    static func matches(texts: [String], keys: [Key]) -> Bool {
        matches(texts.map { [$0] }, keys: keys)
    }

    /// tokens は単語ごとの読み（ならす前のひらがな）
    static func matches(_ tokens: [String], key: Key) -> Bool {
        for i in tokens.indices {
            if key.short {
                // 単語 1 つか、続いた 3 つまでのまとまりがぴったり同じ
                var run = ""
                for j in i..<min(tokens.count, i + 3) {
                    run += tokens[j]
                    if light(run) == key.reading { return true }
                }
            } else {
                // 単語の頭から始まっていればよい（後ろの「だ」「だよ」や活用は気にしない）
                if strong(tokens[i...].joined()).hasPrefix(key.reading) { return true }
            }
        }
        return false
    }

    /// 単語に分け、それぞれの読みをひらがなにする。記号や空白は落とす
    static func words(_ s: String) -> [(surface: String, reading: String)] {
        let cf = s as CFString
        let ns = s as NSString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        guard let tokenizer = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWordBoundary,
                                                      Locale(identifier: "ja_JP") as CFLocale) else {
            let r = hiragana(s, latin: nil)
            return r.isEmpty ? [] : [(s, r)]
        }
        var out: [(surface: String, reading: String)] = []
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while type.rawValue != 0 {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            let reading = hiragana(surface, latin: latin)
            if !reading.isEmpty { out.append((surface, reading)) }
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return out
    }

    /// 1 つの単語の読みをひらがなにする
    static func hiragana(_ surface: String, latin: String?) -> String {
        let text: String
        if surface.unicodeScalars.allSatisfy(\.isASCII) {
            // 英字（DJ、SOS など）はそのまま小文字で比べる
            text = surface
        } else if let latin, !latin.isEmpty {
            // 「zō」のような長音の印を、ひらがなにできる綴りに直す
            var l = latin.precomposedStringWithCanonicalMapping.lowercased()
            for (from, to) in macrons { l = l.replacingOccurrences(of: from, with: to) }
            text = l.applyingTransform(.latinToHiragana, reverse: false) ?? l
        } else {
            text = surface.applyingTransform(.hiraganaToKatakana, reverse: true) ?? surface
        }
        return clean(text.lowercased())
    }

    private static let macrons: [(String, String)] = [
        ("ā", "aa"), ("ī", "ii"), ("ū", "uu"), ("ē", "ee"), ("ō", "ou"),
        ("â", "aa"), ("î", "ii"), ("û", "uu"), ("ê", "ee"), ("ô", "ou"),
    ]

    /// 伸ばす音をそろえる。前の音と同じ母音の「あいうえお」、お段のあとの「う」、え段のあとの「い」を「ー」にする
    /// （「ぞう」「ぞお」「ぞー」→「ぞー」、「けいき」「けえき」「けーき」→「けーき」、「すきい」→「すきー」）
    static func light(_ s: String) -> String {
        var out = ""
        var last: Character?
        for ch in s {
            if ch == "ー" {
                out.append("ー")
                continue
            }
            if let v = last, isLong(ch, after: v) {
                out.append("ー")
                continue
            }
            out.append(ch)
            last = vowel(of: ch)
        }
        return out
    }

    /// 長いお題用。小さい「ぁぃぅぇぉ」を大きくし、伸ばす音を消す（「カンガルー」「かんがるう」→「かんがる」）
    static func strong(_ s: String) -> String {
        let big = String(s.map { smallVowels[$0] ?? $0 })
        return light(big).replacingOccurrences(of: "ー", with: "")
    }

    private static let smallVowels: [Character: Character] = [
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お", "ゎ": "わ",
    ]

    private static let rows: [(vowel: Character, kana: String)] = [
        ("あ", "あかさたなはまやらわがざだばぱぁゃゎ"),
        ("い", "いきしちにひみりぎじぢびぴぃ"),
        ("う", "うくすつぬふむゆるぐずづぶぷぅゅゔ"),
        ("え", "えけせてねへめれげぜでべぺぇ"),
        ("お", "おこそとのほもよろをごぞどぼぽぉょ"),
    ]

    private static func vowel(of ch: Character) -> Character? {
        rows.first(where: { $0.kana.contains(ch) })?.vowel
    }

    private static func isLong(_ ch: Character, after v: Character) -> Bool {
        guard "あいうえお".contains(ch) else { return false }
        return ch == v || (ch == "う" && v == "お") || (ch == "い" && v == "え")
    }

    /// ひらがな・英数字・「ー」だけ残す（カタカナが残っていればひらがなに）
    private static func clean(_ s: String) -> String {
        let hira = s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s
        return String(hira.unicodeScalars.filter { u in
            CharacterSet.alphanumerics.contains(u) || (0x3041...0x309F).contains(Int(u.value)) || u.value == 0x30FC
        }.map(Character.init))
    }

    #if DEBUG
    /// 確かめ用。外れた例を返す（空なら全部合っている）。端末の辞書を使うので、実機かシミュレータで呼ぶ
    static func selfCheck() -> [String] {
        let cases: [(prompt: String, said: String, expect: Bool)] = [
            ("ゾウ", "ぞう", true), ("ゾウ", "ゾウだ！", true), ("ゾウ", "象", true),
            ("ゾウ", "ぞうきん", false), ("ゾウ", "雑巾", false),
            ("スキー", "スキー", true), ("スキー", "好き", false),
            ("カンガルー", "かんがるう", true), ("カンガルー", "カンガルーだよ", true),
            ("傘をさす", "傘さす", true), ("傘をさす", "傘をさす", true),
            ("寿司職人", "すし職人", true), ("DJ", "DJ", true), ("カニ", "カニカマ", false),
        ]
        return cases.compactMap { c in
            matches(texts: [c.said], keys: keys(for: c.prompt)) == c.expect ? nil : "\(c.prompt) ← \(c.said)"
        }
    }
    #endif
}
