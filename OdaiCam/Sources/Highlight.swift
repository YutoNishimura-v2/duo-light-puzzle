@preconcurrency import AVFoundation
import CoreImage
import UIKit

/// ラウンドの録画から、SNS に載せる縦長の種明かし動画（15〜20 秒）を作る。
/// 流れ：つかみ 1 秒（上＝見えていた画面／下＝実際の演技）→ お題ごとに「見えていた画面」→「実際の演技」→ 点数の札 1.5 秒
enum Highlight {
    struct Clip: Sendable {
        let prompt: String
        let outcome: String
        /// しばりの名前（なければ種明かしなしで実際の演技だけ）
        let effect: String?
        /// 録画の頭からの秒数
        let start: TimeInterval
        let end: TimeInterval
        /// 種明かしで流す「見えていた画面」の区間に、人が映っていたか（しばりなしは全部映っていたことに）
        var seenQuality: SeenQuality = .full
        /// つかみ（答える直前の 1 秒）の区間に、人が映っていたか
        var hookQuality: SeenQuality = .full
    }

    /// 書き出しの大きさ（縦長・30 fps）
    static let renderSize = CGSize(width: 1080, height: 1920)
    /// 最初のつかみ
    static let hookLength = 1.0
    /// 最後の点数の札
    static let endLength = 1.5
    /// 1 つのお題で見せる長さ。見えていた画面と実際の演技は同じ場面の頭から流す（合わせて 3 秒まで）
    static let seenLength = 1.3
    static let realLength = 1.7
    /// 見えていた画面がないお題は、実際の演技だけをこの長さで
    static let realOnlyLength = 2.4
    /// 答えたあとの反応を少しだけ残す
    static let after = 0.3
    /// 動画全体の長さの上限
    static let maxTotal = 20.0

    private enum Kind { case hook, seen, real, end }

    private struct Piece {
        let kind: Kind
        let caption: String
        /// 合成の中の区間（入れた区間と同じ値を使い、指示との間にすき間を作らない）
        let time: CMTimeRange
        /// 当てる人の顔が入っているか
        var face = false
        /// 上下に分けた画面か（つかみと、顔つきの実際の演技）
        var split = false
        /// つかみで上が見えていた画面か（false なら上は当てる人の顔）
        var topIsSeen = false
        /// 直前が見えていた画面（＝種明かしの瞬間）
        var reveal = false
        var at: Double { time.start.seconds }
        var length: Double { time.duration.seconds }
    }

    private struct Source {
        /// 元の動画。トラックは動画を弱くしか持たないので、書き出し終わるまでここで持っておく
        /// （手放すと、書き出しの途中で読めなくなり -11800/-12780 で失敗する）
        let asset: AVAsset
        let track: AVAssetTrack
        let size: CGSize
        let transform: CGAffineTransform
        /// 映像の終わり（秒）
        let end: Double
    }

    /// 効果音・BGM（アプリに入れた wav）
    private struct Tone {
        let asset: AVAsset
        let track: AVAssetTrack
        let duration: CMTime
    }

    /// 合成の 1 本のトラックと、いまどこまで埋まっているか。前から順にしか入れない
    private final class Lane {
        let track: AVMutableCompositionTrack
        var end = CMTime.zero
        var used = false
        init(_ track: AVMutableCompositionTrack) { self.track = track }

        /// at の位置に入れる。すき間は空で埋める。前のものと重なるなら入れずに false
        @discardableResult
        func put(_ range: CMTimeRange, of source: AVAssetTrack, at: CMTime) throws -> Bool {
            guard at >= end, range.duration > .zero else { return false }
            if at > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            try track.insertTimeRange(range, of: source, at: at)
            end = at + range.duration
            used = true
            return true
        }

        /// 終わりを total まで空で埋める
        func pad(to total: CMTime) {
            if total > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: total)) }
            end = CMTimeMaximum(end, total)
        }
    }

    private static func load(_ url: URL) async throws -> (Source, AVAssetTrack?)? {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let range = try await video.load(.timeRange)
        let duration = try await asset.load(.duration).seconds
        let end = range.end.seconds.isFinite ? min(range.end.seconds, duration) : duration
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        return (Source(asset: asset, track: video, size: size, transform: transform, end: end), audio)
    }

    private static func loadSound(_ name: String) async -> Tone? {
        guard let url = Sound.url(name) else {
            CrashLog.mark("ハイライト：音 \(name) がありません")
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange), range.duration > .zero else { return nil }
        return Tone(asset: asset, track: track, duration: range.duration)
    }

    private static func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    /// score が nil なら正解の数を点数にする。overlay・useSeen は、試験で失敗の場所を絞るときだけ切る。
    /// language は帯の文字の言葉（山札の言葉。"ja" か "en"）。Clip.effect は呼ぶ側でこの言葉にしておく
    static func make(raw: URL, seen: URL?, front: URL?, clips: [Clip], score: Int? = nil,
                     overlay: Bool = true, useSeen: Bool = true, language: String = "ja") async throws -> URL {
        /// 帯の文字を language で引く（鍵は日本語）
        func word(_ key: String) -> String { Words.text(key, language: language) }
        guard let rawLoaded = try await load(raw) else { throw failure("映像がありません") }
        let (rawSource, audioTrack) = rawLoaded
        var seenSource: Source?
        if let seen, useSeen { seenSource = try await load(seen)?.0 }
        // 当てる人の顔
        var frontSource: Source?
        if let front { frontSource = try await load(front)?.0 }
        let margin = 0.02
        var audioEnd = 0.0
        if let audioTrack, let r = try? await audioTrack.load(.timeRange) { audioEnd = r.end.seconds - margin }

        let bgm = await loadSound("bgm")
        let riser = await loadSound("riser")
        let hit = await loadSound("hit")
        let whoosh = await loadSound("whoosh")
        let fanfare = await loadSound("finish")

        // ---- どのお題をどれだけ使うか ----
        // 終わりぎりぎりは秒の丸めで元の映像からはみ出すので、少し手前までにする
        let rawEnd = rawSource.end - margin
        let seenEnd = (seenSource?.end ?? 0) - margin
        let faceEnd = (frontSource?.end ?? 0) - margin

        struct Plan {
            let index: Int
            let clip: Clip
            /// 実際の演技の区間（録画の秒）
            let from: Double
            let to: Double
            /// 見えていた画面の長さ（0 なら出さない）。from から流す
            let seenLength: Double
            var cost: Double { seenLength + to - from }
        }
        /// withSeen が false なら、見えていた画面を出さずに実際の演技だけにする
        func plan(_ i: Int, _ clip: Clip, withSeen: Bool) -> Plan? {
            let to = min(clip.end + after, rawEnd)
            let hasSeen = withSeen && seenSource != nil && clip.effect != nil
            let from = max(clip.start, to - (hasSeen ? realLength : realOnlyLength), 0)
            guard to - from >= 0.5 else { return nil }
            var seenFor = hasSeen ? min(Self.seenLength, to - from, seenEnd - from) : 0
            if seenFor < 0.4 { seenFor = 0 }
            return Plan(index: i, clip: clip, from: from, to: to, seenLength: seenFor)
        }
        /// 見えていた画面に 1 秒以上なにも映っていない（棒人間・影絵・背景が人を見つけられなかった）
        func blank(_ clip: Clip) -> Bool {
            seenSource != nil && clip.effect != nil && clip.seenQuality.hasEmptyGap
        }
        // 空の画面のお題は使わない。全部そうなら、実際の演技だけにして使う
        var plans: [Plan] = clips.enumerated().compactMap { i, clip in
            blank(clip) ? nil : plan(i, clip, withSeen: true)
        }
        if plans.isEmpty {
            plans = clips.enumerated().compactMap { i, clip in plan(i, clip, withSeen: !blank(clip)) }
        }
        let blanks = clips.filter { blank($0) }.count
        if blanks > 0 { CrashLog.mark("ハイライト：人が映っていないお題 \(blanks) 個") }
        guard !plans.isEmpty else { throw failure("使える場面がありません") }

        // 面白い順：正解は当てるまで長くかかったものほど上、次にパス。同じなら前のお題
        func rank(_ clip: Clip, _ index: Int) -> (Int, Double, Int) {
            (clip.outcome == "○" ? 2 : clip.outcome == "パス" ? 1 : 0, clip.end - clip.start, -index)
        }
        let ranked = plans.sorted { rank($0.clip, $0.index) > rank($1.clip, $1.index) }

        // つかみ：答える直前の 1 秒を上下に並べる。上が見えていた画面なら、人がいちばんよく映っていたお題
        // （映り方が同じなら面白い順）。人がほとんど映っていなければ、当てる人の顔にする
        let byFun = clips.indices.sorted { rank(clips[$0], $0) > rank(clips[$1], $1) }
        /// 映っていた割合は 5% 刻みで比べる（細かい差より面白さを優先）
        func visibility(_ clip: Clip) -> Int { Int((clip.hookQuality.visibleFraction * 20).rounded()) }
        var hook: (from: Double, length: Double, topIsSeen: Bool, effect: String?)?
        if seenSource != nil {
            let byVisibility = byFun.filter { clips[$0].effect != nil }.enumerated()
                .sorted { a, b in
                    let va = visibility(clips[a.element]), vb = visibility(clips[b.element])
                    return va != vb ? va > vb : a.offset < b.offset
                }
                .map { $0.element }
            for i in byVisibility {
                let c = clips[i]
                // 半分も映っていないなら、空の画面をつかみにしない（顔があれば顔、なければ上下に分けない）
                if c.hookQuality.visibleFraction < 0.5 { break }
                let e = min(c.end, rawEnd, seenEnd)
                let s = max(c.start, e - hookLength, 0)
                if e - s >= 0.6 { hook = (s, e - s, true, c.effect); break }
            }
        }
        if hook == nil, frontSource != nil {
            for i in byFun {
                let c = clips[i]
                let e = min(c.end, rawEnd, faceEnd)
                let s = max(c.start, e - hookLength, 0)
                if e - s >= 0.6 { hook = (s, e - s, false, nil); break }
            }
        }

        // 時間に収まる分だけ、面白い順に取り、お題の順に並べ直す
        var budget = maxTotal - (hook?.length ?? 0) - endLength
        var chosen: [Plan] = []
        for p in ranked where p.cost <= budget + 0.001 {
            chosen.append(p)
            budget -= p.cost
        }
        chosen.sort { $0.index < $1.index }

        // ---- 合成 ----
        let composition = AVMutableComposition()
        func addLane(_ type: AVMediaType) throws -> Lane {
            guard let t = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw failure("合成できません")
            }
            return Lane(t)
        }
        let rawLane = try addLane(.video)
        let seenLane = try addLane(.video)
        let faceLane = try addLane(.video)
        // 録画の声・BGM・上がる音・ドンなどの効果音（重なるので分ける）
        let voiceLane = try addLane(.audio)
        let bgmLane = try addLane(.audio)
        let riserLane = try addLane(.audio)
        let sfxLane = try addLane(.audio)

        func range(_ from: Double, _ length: CMTime) -> CMTimeRange { CMTimeRange(start: cm(from), duration: length) }

        /// 同じ場面の当てる人の顔を入れる。最後まで映っていなければ入れない
        func putFace(_ from: Double, _ length: CMTime, at: CMTime) -> Bool {
            guard let frontSource, from + length.seconds <= faceEnd + 0.1 else { return false }
            let usable = CMTimeMinimum(length, cm(faceEnd - from))
            return (try? faceLane.put(range(from, usable), of: frontSource.track, at: at)) ?? false
        }
        /// 録画の声（実際の演技のときだけ。見えていた画面のあいだは答えが聞こえないよう入れない）
        func putVoice(_ from: Double, _ length: CMTime, at: CMTime) {
            guard let audioTrack else { return }
            let usable = CMTimeMinimum(length, cm(audioEnd - from))
            guard usable.seconds > 0.1 else { return }
            try? voiceLane.put(range(from, usable), of: audioTrack, at: at)
        }

        var pieces: [Piece] = []
        var cursor = CMTime.zero
        if let hook {
            let d = cm(hook.length)
            let ok: Bool
            if hook.topIsSeen, let seenSource {
                ok = try seenLane.put(range(hook.from, d), of: seenSource.track, at: cursor)
            } else {
                ok = putFace(hook.from, d, at: cursor)
            }
            if ok {
                try rawLane.put(range(hook.from, d), of: rawSource.track, at: cursor)
                pieces.append(Piece(kind: .hook,
                                    caption: !hook.topIsSeen
                                        ? word("当てる人の顔↑　正解はコレ↓")
                                        : hook.effect.map { String(format: word("見えてたのはコレ（%@）↑　正解はコレ↓"), $0) }
                                            ?? word("見えてたのはコレ↑　正解はコレ↓"),
                                    time: CMTimeRange(start: cursor, duration: d),
                                    face: !hook.topIsSeen, split: true, topIsSeen: hook.topIsSeen))
                cursor = cursor + d
            }
        }
        for p in chosen {
            var reveal = false
            if p.seenLength > 0, let seenSource, let effect = p.clip.effect {
                let d = cm(p.seenLength)
                if try seenLane.put(range(p.from, d), of: seenSource.track, at: cursor) {
                    let face = putFace(p.from, d, at: cursor)
                    pieces.append(Piece(kind: .seen, caption: String(format: word("見えていたのは…（%@）"), effect),
                                        time: CMTimeRange(start: cursor, duration: d), face: face))
                    cursor = cursor + d
                    reveal = true
                }
            }
            let d = cm(p.to - p.from)
            try rawLane.put(range(p.from, d), of: rawSource.track, at: cursor)
            putVoice(p.from, d, at: cursor)
            let face = putFace(p.from, d, at: cursor)
            // 結果の印（○・パス）は帯に出すときだけ訳す。並べ替えは日本語の印のまま比べる
            pieces.append(Piece(kind: .real, caption: String(format: word("お題：%@　%@"), p.clip.prompt, word(p.clip.outcome)),
                                time: CMTimeRange(start: cursor, duration: d), face: face, split: face, reveal: reveal))
            cursor = cursor + d
        }
        guard pieces.contains(where: { $0.kind == .real }) else { throw failure("使える場面がありません") }

        // 点数の札。札の絵は 2 回目で上から不透明に重ねる。1 回目はここに「毎コマ変わる」映像を入れておく。
        // （変わらない映像・不透明度 0 の映像だと、1 回目の書き出しが札の 1.5 秒を 1 コマにまとめてしまい、
        //   2 回目の重ね書きがそのコマ（札の始まりの瞬間）に 1 回しか呼ばれず、真っ黒のまま残る）
        // 生の映像が札の長さに足りなければ、あるだけ入れて札の長さまで引きのばす
        let endD = cm(endLength)
        let endStart = cursor
        var endHasRaw = false
        let endAvail = min(endLength, rawEnd)
        if endAvail >= 0.1 {
            let d = cm(endAvail)
            if (try? rawLane.put(range(rawEnd - endAvail, d), of: rawSource.track, at: endStart)) == true {
                if d < endD {
                    rawLane.track.scaleTimeRange(CMTimeRange(start: endStart, duration: d), toDuration: endD)
                    rawLane.end = endStart + endD
                }
                endHasRaw = true
            }
        }
        pieces.append(Piece(kind: .end, caption: "", time: CMTimeRange(start: endStart, duration: endD)))
        let total = endStart + endD
        rawLane.pad(to: total)

        // ---- 音 ----
        // BGM は最初から最後まで繰り返す
        if let bgm {
            var at = CMTime.zero
            while at < total {
                let length = CMTimeMinimum(bgm.duration, total - at)
                guard (try? bgmLane.put(CMTimeRange(start: .zero, duration: length), of: bgm.track, at: at)) == true else { break }
                at = at + length
            }
        }
        /// 効果音を at から入れる（total を越える分は切る）
        func putSound(_ sound: Tone?, at: CMTime, on lane: Lane, skip: CMTime = .zero) {
            guard let sound, at >= .zero else { return }
            let length = CMTimeMinimum(sound.duration - skip, total - at)
            guard length > .zero else { return }
            try? lane.put(CMTimeRange(start: skip, duration: length), of: sound.track, at: at)
        }
        for piece in pieces {
            switch piece.kind {
            case .hook:
                // つかみから本編へのつなぎ
                if let whoosh { putSound(whoosh, at: piece.time.end - CMTime(value: 15, timescale: 60), on: sfxLane) }
            case .seen:
                // 上がっていく音。終わりが種明かしの瞬間にそろうよう、長ければ頭を切る
                if let riser {
                    let length = CMTimeMinimum(riser.duration, piece.time.duration)
                    putSound(riser, at: piece.time.end - length, on: riserLane, skip: riser.duration - length)
                }
            case .real:
                if piece.reveal {
                    putSound(hit, at: piece.time.start, on: sfxLane)
                } else if let whoosh {
                    putSound(whoosh, at: piece.time.start - CMTime(value: 12, timescale: 60), on: sfxLane)
                }
            case .end:
                // 上がる音のトラックは種明かしの前で必ず空くので、ファンファーレはそちらに入れる
                putSound(fanfare, at: piece.time.start, on: riserLane)
            }
        }

        // 中身のないトラックは外す（外したトラックは指示や音量で触らない）
        for lane in [seenLane, faceLane, voiceLane, bgmLane, riserLane, sfxLane] where !lane.used {
            composition.removeTrack(lane.track)
        }

        // ---- 音量 ----
        // BGM はふだん大きめ、実際の演技（録画の声）のあいだは下げる。最後は札の上で消えていく
        let bgmHigh: Float = 0.5
        let bgmLow: Float = 0.12
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if bgmLane.used {
            let p = AVMutableAudioMixInputParameters(track: bgmLane.track)
            // 音量の変化は区間が重ならないようにする（重なると AVFoundation が受け付けない）
            if pieces.first?.kind != .real {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: bgmHigh, timeRange: CMTimeRange(start: .zero, duration: cm(0.05)))
            }
            for piece in pieces where piece.kind == .real {
                let ramp = cm(min(0.15, piece.length / 3))
                p.setVolumeRamp(fromStartVolume: piece.time.start == .zero ? 0 : bgmHigh, toEndVolume: bgmLow,
                                timeRange: CMTimeRange(start: piece.time.start, duration: ramp))
                p.setVolumeRamp(fromStartVolume: bgmLow, toEndVolume: bgmHigh,
                                timeRange: CMTimeRange(start: piece.time.end - ramp, duration: ramp))
            }
            let fadeOut = cm(1.0)
            p.setVolumeRamp(fromStartVolume: bgmHigh, toEndVolume: 0, timeRange: CMTimeRange(start: total - fadeOut, duration: fadeOut))
            mixParams.append(p)
        }
        if voiceLane.used {
            // 切れ目でプチッと鳴らないよう、場面の頭と終わりを短くなだらかに
            let p = AVMutableAudioMixInputParameters(track: voiceLane.track)
            let edge = cm(0.04)
            for piece in pieces where piece.kind == .real {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: piece.time.start, duration: edge))
                p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: piece.time.end - edge, duration: edge))
            }
            mixParams.append(p)
        }
        for (lane, volume) in [(riserLane, Float(0.8)), (sfxLane, Float(0.85))] where lane.used {
            let p = AVMutableAudioMixInputParameters(track: lane.track)
            p.setVolume(volume, at: .zero)
            mixParams.append(p)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams

        // ---- 映像の並べ方（変形と切り抜きだけで組む。シミュレータでも同じ形になる） ----
        let w = renderSize.width, h = renderSize.height
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let top = CGRect(x: 0, y: 0, width: w, height: h / 2)
        let bottom = CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        // 見えていた画面の上に出す小さな顔の窓。上半分と同じ縦横比にして、種明かしでそのまま上半分へ広げる
        let wipeWidth = w * 0.3
        let wipe = CGRect(x: w * 0.03, y: w * 0.03, width: wipeWidth, height: wipeWidth * top.height / top.width)

        func layer(_ lane: Lane, _ source: Source, _ region: CGRect, focus: CGFloat, at: CMTime) -> AVMutableVideoCompositionLayerInstruction {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: lane.track)
            let f = fill(source, region, focusY: focus)
            l.setCropRectangle(f.crop, at: at)
            l.setTransform(f.transform, at: at)
            return l
        }
        let compositionEnd = composition.duration
        let instructions: [AVMutableVideoCompositionInstruction] = pieces.enumerated().map { i, piece in
            let instruction = AVMutableVideoCompositionInstruction()
            var timeRange = piece.time
            // 最後の指示は合成の終わりにぴったり合わせる
            if i == pieces.count - 1, compositionEnd > timeRange.start { timeRange = CMTimeRange(start: timeRange.start, end: compositionEnd) }
            instruction.timeRange = timeRange
            let start = timeRange.start
            // 先頭の指示ほど上に描かれる
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            switch piece.kind {
            case .hook:
                if piece.topIsSeen, let seenSource, seenLane.used {
                    layers.append(layer(seenLane, seenSource, top, focus: 0.42, at: start))
                } else if let frontSource, faceLane.used {
                    layers.append(layer(faceLane, frontSource, top, focus: 0.45, at: start))
                }
                layers.append(layer(rawLane, rawSource, bottom, focus: 0.42, at: start))
            case .seen:
                if piece.face, let frontSource, faceLane.used {
                    layers.append(layer(faceLane, frontSource, wipe, focus: 0.45, at: start))
                }
                if let seenSource, seenLane.used {
                    layers.append(layer(seenLane, seenSource, full, focus: 0.5, at: start))
                }
            case .real:
                if piece.face, let frontSource, faceLane.used {
                    // 当てる人の顔が主役：左上の小窓から上半分へ広げる
                    let l = AVMutableVideoCompositionLayerInstruction(assetTrack: faceLane.track)
                    let big = fill(frontSource, top, focusY: 0.45)
                    l.setCropRectangle(big.crop, at: start)
                    if piece.reveal {
                        let small = fill(frontSource, wipe, focusY: 0.45)
                        let grow = min(0.25, piece.length / 2)
                        l.setTransformRamp(fromStart: small.transform, toEnd: big.transform,
                                           timeRange: CMTimeRange(start: start, duration: cm(grow)))
                    } else {
                        l.setTransform(big.transform, at: start)
                    }
                    layers.append(l)
                    layers.append(layer(rawLane, rawSource, bottom, focus: 0.42, at: start))
                } else {
                    layers.append(layer(rawLane, rawSource, full, focus: 0.5, at: start))
                }
            case .end:
                if endHasRaw {
                    // 不透明度を毎コマ変えて、1 回目でも 30 fps で 1 コマずつ描かせる。
                    // 2 回目の札（不透明な黒地）で全部隠れる。帯の重ね書きに失敗したときは暗く消えていく終わり方になる
                    let l = layer(rawLane, rawSource, full, focus: 0.5, at: start)
                    l.setOpacityRamp(fromStartOpacity: 0.5, toEndOpacity: 0, timeRange: timeRange)
                    layers.append(l)
                }
            }
            instruction.layerInstructions = layers
            return instruction
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        // 1 回目：映像の並べ方と音だけで書き出す（音はここで仕上げる。2 回目はそのまま写す）
        let temp = FileManager.default.temporaryDirectory
        let step1 = temp.appendingPathComponent("highlight-base-\(UUID().uuidString).mp4")
        // HighestQuality は H.264 で、renderSize の大きさのまま書き出す（大きさ指定のプリセットは縮むので使わない）
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw failure("書き出せません")
        }
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: step1, as: .mp4)

        // 2 回目：文字の帯・ロゴ・光・札を Core Image で重ねる。
        // CoreAnimation の重ね絵はシミュレータで落ちるので使わない（Core Image ならシミュレータでも実機でも同じ絵になる）
        var result = step1
        if overlay {
            let out = temp.appendingPathComponent("highlight-\(UUID().uuidString).mp4")
            let base = AVURLAsset(url: step1)
            do {
                let points = score ?? clips.filter { $0.outcome == "○" }.count
                let parts = await overlayParts(size: renderSize, pieces: pieces, wipe: faceLane.used ? wipe : nil, score: points,
                                               unit: word("点"))
                let overlaid = try await AVMutableVideoComposition.videoComposition(with: base, applyingCIFiltersWithHandler: { request in
                    request.finish(with: parts.frame(request.sourceImage, at: request.compositionTime.seconds), context: nil)
                })
                overlaid.frameDuration = CMTime(value: 1, timescale: 30)
                guard let second = AVAssetExportSession(asset: base, presetName: AVAssetExportPresetHighestQuality) else {
                    throw failure("帯を重ねて書き出せません")
                }
                second.videoComposition = overlaid
                second.shouldOptimizeForNetworkUse = true
                try await second.export(to: out, as: .mp4)
                result = out
            } catch {
                // 帯だけの失敗で動画ごと失くさない。帯なしの 1 回目をそのまま渡す
                CrashLog.mark("ハイライト：帯の重ね書きに失敗、帯なしで出す：\((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: out)
            }
            withExtendedLifetime(base) {}
            if result != step1 { try? FileManager.default.removeItem(at: step1) }
        }
        // 元の動画と音を書き出しの終わりまで手放さない
        withExtendedLifetime([rawSource.asset, seenSource?.asset, frontSource?.asset,
                              bgm?.asset, riser?.asset, hit?.asset, whoosh?.asset, fanfare?.asset]) {}
        return result
    }

    /// 失敗の文言は結果の画面に出るので、端末の言葉で書く
    private static func failure(_ message: String.LocalizationValue) -> NSError {
        NSError(domain: "Highlight", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: message)])
    }

    /// 元の映像を region いっぱいに敷く（はみ出す分は切り抜く）。切り抜きは元の映像の座標、変形は合成の座標（左上が原点）
    /// focusY は縦に余るときにどこを残すか（0＝上、0.5＝真ん中）
    private static func fill(_ source: Source, _ region: CGRect, focusY: CGFloat) -> (crop: CGRect, transform: CGAffineTransform) {
        let natural = CGRect(origin: .zero, size: source.size)
        // 向きを直した後の枠を原点にそろえる
        let turned = natural.applying(source.transform)
        let upright = source.transform.concatenating(CGAffineTransform(translationX: -turned.minX, y: -turned.minY))
        let sw = turned.width, sh = turned.height
        guard sw > 0, sh > 0, region.width > 0, region.height > 0 else { return (natural, .identity) }
        let s = max(region.width / sw, region.height / sh)
        let vw = min(sw, region.width / s), vh = min(sh, region.height / s)
        let vx = (sw - vw) / 2
        let vy = min(max((sh - vh) * focusY, 0), sh - vh)
        let crop = CGRect(x: vx, y: vy, width: vw, height: vh).applying(upright.inverted())
        let transform = upright
            .concatenating(CGAffineTransform(translationX: -vx, y: -vy))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: region.minX, y: region.minY))
        return (crop, transform)
    }

    /// base に top を amount（0〜1）の濃さで重ねる。ただの割合の混ぜ合わせなので、透明度の持ち方に左右されない
    private static func mix(_ top: CIImage, over base: CIImage, _ amount: Double) -> CIImage {
        let full = top.composited(over: base)
        guard amount < 1 else { return full }
        return base.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: full,
            kCIInputTimeKey: max(amount, 0),
        ])
    }

    /// ぽんと出る大きさ：0.22 秒で from → 1.08 → 1.0（前の CoreAnimation と同じ動き）
    private static func popScale(_ elapsed: Double, from: Double) -> Double {
        let length = 0.22, peak = 0.22 * 0.6
        if elapsed <= 0 { return from }
        if elapsed >= length { return 1 }
        if elapsed < peak { return from + (1.08 - from) * elapsed / peak }
        return 1.08 + (1.0 - 1.08) * (elapsed - peak) / (length - peak)
    }

    /// center を中心に大きさを変える
    private static func scaled(_ image: CIImage, _ scale: Double, about center: CGPoint) -> CIImage {
        guard scale != 1 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    /// 重ね絵の部品。書き出す前に 1 回だけ描いておき、コマごとには出すかどうか・濃さ・大きさだけ変える
    /// 位置は Core Image の座標（左下が原点）。作り終えたら読むだけなので、別のスレッドから使ってよい
    private final class Overlay: @unchecked Sendable {
        struct Span {
            let from: Double
            let to: Double
            init(_ piece: Piece) { from = piece.at; to = piece.at + piece.length }
            func has(_ t: Double) -> Bool { t >= from && t < to }
        }
        struct Chip {
            let image: CIImage
            /// ぽんと出るときの中心
            let center: CGPoint
            let span: Span
        }
        let extent: CGRect
        /// 上下の分け目の黒線
        var seam: CIImage?
        var seamSpans: [Span] = []
        /// 顔の小窓の黒い縁
        var border: CIImage?
        var borderSpans: [Span] = []
        /// 種明かしの瞬間（白く光らせる始まりの秒）
        var flashes: [Double] = []
        let white: CIImage
        var chips: [Chip] = []
        /// 上の中央のロゴ。markUntil から先は消す
        var mark: CIImage?
        var markUntil = Double.infinity
        /// 最後の札：黒地とロゴ、その上にぽんと出る点数
        var card: CIImage?
        var number: CIImage?
        var cardAt = Double.infinity
        /// 札の出はじめを判定するときのゆとり（半コマ）
        static let slack = 1.0 / 60

        init(size: CGSize) {
            extent = CGRect(origin: .zero, size: size)
            white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        }

        /// t 秒のコマに重ねる。重ねる順は前と同じ（分け目 → 縁 → 光 → 帯 → ロゴ → 札）
        func frame(_ source: CIImage, at t: Double) -> CIImage {
            var out = source
            func put(_ image: CIImage?, _ alpha: Double = 1) {
                guard let image, alpha > 0 else { return }
                out = Highlight.mix(image, over: out, alpha)
            }
            if seamSpans.contains(where: { $0.has(t) }) { put(seam) }
            if borderSpans.contains(where: { $0.has(t) }) { put(border) }
            for at in flashes where t >= at && t < at + 0.2 {
                put(white, 0.7 * (1 - (t - at) / 0.2))
            }
            for chip in chips where chip.span.has(t) {
                put(Highlight.scaled(chip.image, Highlight.popScale(t - chip.span.from, from: 0.6), about: chip.center))
            }
            // コマの時刻は秒の丸めで札の始まりのわずかに手前になることがあるので、半コマ分ゆるくする
            let showCard = card != nil && t + Self.slack >= cardAt
            if t + Self.slack < markUntil || card == nil { put(mark) }
            if showCard, let card {
                // 札は黒地の不透明な絵なので、薄く混ぜずにすぱっと切り替える（最初のコマから点数が見える）。
                // 点数だけ小さくぽんと出す
                var face = card
                if let number {
                    let center = CGPoint(x: extent.midX, y: extent.midY)
                    let elapsed = max(t - cardAt, 0)
                    face = Highlight.scaled(number, Highlight.popScale(elapsed, from: 0.85), about: center).composited(over: card)
                }
                out = face.composited(over: out)
            }
            return out.cropped(to: source.extent)
        }
    }

    /// 文字と札の絵を描いておく。描くときは UIKit の座標（左上が原点）、置くときに Core Image の座標へ直す
    @MainActor
    private static func overlayParts(size: CGSize, pieces: [Piece], wipe: CGRect?, score: Int, unit unitText: String) -> Overlay {
        let w = size.width, h = size.height
        let parts = Overlay(size: size)
        // 色はブランドの黄色ひとつだけ。種明かしの瞬間にだけ使う
        let yellow = UIColor(red: 1, green: 0.87, blue: 0.43, alpha: 1)
        // CALayer の shadowRadius 12 と同じくらいのぼかし（Core Graphics のぼかしは倍の数で同じくらい）
        let shadowBlur: CGFloat = 24
        // 影がはみ出す分の余白
        let pad: CGFloat = 32

        func markFont(_ size: CGFloat) -> UIFont {
            UIFont(name: "OdaiCamInter-ExtraBold", size: size) ?? UIFont.systemFont(ofSize: size, weight: .heavy)
        }
        /// rect（UIKit の座標）の中に描いて、動画の同じ場所に置く絵にする。body の中は rect の左上が原点
        func draw(_ rect: CGRect, _ body: (CGContext) -> Void) -> CIImage? {
            let r = rect.integral
            guard r.width > 0, r.height > 0 else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: r.size, format: format).image { context in
                let cg = context.cgContext
                cg.translateBy(x: rect.minX - r.minX, y: rect.minY - r.minY)
                body(cg)
            }
            guard let cgImage = image.cgImage else { return nil }
            return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: r.minX, y: h - r.maxY))
        }
        /// 丸い札。centerY は上からの位置
        func pill(_ text: String, yellow isYellow: Bool, centerY: CGFloat, piece: Piece) {
            let height = h * 0.055
            let color = isYellow ? UIColor.black : UIColor.white
            var font = UIFont.systemFont(ofSize: height * 0.46, weight: .heavy)
            var textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            // 長いお題は字を小さくして収める
            let maxText = w * 0.9 - height
            if textWidth > maxText {
                font = UIFont.systemFont(ofSize: font.pointSize * maxText / textWidth, weight: .heavy)
                textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            }
            let width = textWidth + height
            let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let lineHeight = font.lineHeight
            let rect = CGRect(x: (w - width) / 2 - pad, y: centerY - height / 2 - pad, width: width + pad * 2, height: height + pad * 2)
            let image = draw(rect) { cg in
                let chip = CGRect(x: pad, y: pad, width: width, height: height)
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: shadowBlur, color: UIColor(white: 0, alpha: 0.35).cgColor)
                cg.setFillColor((isYellow ? yellow : UIColor(white: 0.08, alpha: 0.85)).cgColor)
                cg.addPath(UIBezierPath(roundedRect: chip, cornerRadius: height / 2).cgPath)
                cg.fillPath()
                cg.restoreGState()
                label.draw(at: CGPoint(x: chip.minX + height / 2, y: chip.minY + (height - lineHeight) / 2))
            }
            if let image {
                parts.chips.append(Overlay.Chip(image: image, center: CGPoint(x: w / 2, y: h - centerY), span: Overlay.Span(piece)))
            }
        }

        // 上下の分け目の細い黒線
        parts.seam = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: h / 2 - h * 0.002, width: w, height: h * 0.004))
        // 顔の小窓の黒い縁（BeReal の自撮りの窓と同じ）。縁の太さは内側へ
        if let wipe {
            let frame = wipe.insetBy(dx: -w * 0.006, dy: -w * 0.006)
            let line = w * 0.008
            parts.border = draw(frame) { cg in
                let box = CGRect(origin: .zero, size: frame.size)
                cg.setFillColor(UIColor.black.cgColor)
                cg.fill(box)
                cg.clear(box.insetBy(dx: line, dy: line))
            }
        }

        for piece in pieces {
            if piece.split { parts.seamSpans.append(Overlay.Span(piece)) }
            switch piece.kind {
            case .hook:
                pill(piece.caption, yellow: piece.topIsSeen, centerY: h / 2, piece: piece)
            case .seen:
                if piece.face, wipe != nil { parts.borderSpans.append(Overlay.Span(piece)) }
                pill(piece.caption, yellow: false, centerY: h * 0.8, piece: piece)
            case .real:
                pill(piece.caption, yellow: true, centerY: piece.split ? h / 2 : h * 0.8, piece: piece)
                // 種明かしの瞬間に白く光らせる（0.7 から 0.2 秒で消える）
                if piece.reveal { parts.flashes.append(piece.at) }
            case .end:
                break
            }
        }

        // 上の中央にロゴ。大きさは前のまま、どんな背景でも読めるよう柔らかい影をつける
        let markHeight = h * 0.045
        let markText = NSAttributedString(string: "OdaiCam.", attributes: [
            .font: markFont(markHeight * 0.72),
            .foregroundColor: UIColor.white,
            .kern: -markHeight * 0.025,
        ])
        parts.mark = draw(CGRect(x: 0, y: h * 0.025 - pad, width: w, height: markHeight + pad * 2)) { cg in
            cg.setShadow(offset: .zero, blur: shadowBlur, color: UIColor(white: 0, alpha: 0.7).cgColor)
            let textSize = markText.size()
            markText.draw(at: CGPoint(x: (w - textSize.width) / 2, y: pad))
        }

        // 最後の札：黒地に大きな点数と「点」、その下に控えめにロゴ
        if let end = pieces.last(where: { $0.kind == .end }) {
            // 札の間は上のロゴを消す（札のロゴと二重にしない）
            parts.markUntil = end.at
            parts.cardAt = end.at
            let full = CGRect(origin: .zero, size: size)

            let logoHeight = h * 0.04
            let logo = NSAttributedString(string: "OdaiCam.", attributes: [
                .font: markFont(logoHeight * 0.72),
                .foregroundColor: UIColor(white: 1, alpha: 0.6),
                .kern: -logoHeight * 0.025,
            ])
            parts.card = draw(full) { cg in
                cg.setFillColor(UIColor.black.cgColor)
                cg.fill(full)
                let logoSize = logo.size()
                // 下から 3 割の高さ（上から数えると 1 - 0.3 - 0.04）
                logo.draw(at: CGPoint(x: (w - logoSize.width) / 2, y: h - h * 0.3 - logoHeight))
            }

            let numberFont = markFont(h * 0.17)
            let unitFont = UIFont.systemFont(ofSize: h * 0.06, weight: .heavy)
            let number = NSAttributedString(string: "\(score)", attributes: [
                .font: numberFont, .foregroundColor: UIColor.white, .kern: -h * 0.004,
            ])
            let unit = NSAttributedString(string: unitText, attributes: [.font: unitFont, .foregroundColor: UIColor.white])
            let numberWidth = ceil(number.size().width)
            let unitWidth = ceil(unit.size().width)
            let gap = w * 0.02
            let left = (w - numberWidth - gap - unitWidth) / 2
            // 数字と「点」の下端（文字の並ぶ線）をそろえる。下から 47% の高さ
            let baseline = h - h * 0.47
            parts.number = draw(full) { _ in
                number.draw(at: CGPoint(x: left, y: baseline - numberFont.ascender))
                unit.draw(at: CGPoint(x: left + numberWidth + gap, y: baseline - unitFont.ascender))
            }
        }
        return parts
    }
}
