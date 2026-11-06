@preconcurrency import AVFoundation
import UIKit

/// ラウンドの録画から、お題ごとに「当てる人が見ていた画面」→「実際の演技」の順で種明かしをつなぐ
enum Highlight {
    struct Clip: Sendable {
        let prompt: String
        let outcome: String
        /// しばりの名前（なければ種明かしなしで実際の演技だけ）
        let effect: String?
        /// 録画の頭からの秒数
        let start: TimeInterval
        let end: TimeInterval
    }

    /// 1 つのお題から使う長さ。答える直前の山場を中心に取る
    static let before = 3.5
    static let after = 0.8

    private struct Piece {
        let caption: String
        let at: Double
        let length: Double
        /// true なら当てる人が見ていた画面、false なら実際の演技
        let seen: Bool
        /// 合成の中の区間（入れた区間と同じ値を使い、指示との間にすき間を作らない）
        let time: CMTimeRange
    }

    private struct Source {
        /// 元の動画。トラックは動画を弱くしか持たないので、書き出し終わるまでここで持っておく
        /// （手放すと、書き出しの途中で読めなくなり -11800/-12780 で失敗する）
        let asset: AVAsset
        let track: AVAssetTrack
        let size: CGSize
        let duration: Double
    }

    private static func load(_ url: URL) async throws -> (Source, AVAssetTrack?)? {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await video.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        return (Source(asset: asset, track: video, size: size, duration: duration), audio)
    }

    /// overlay・useSeen は、試験で失敗の場所を絞るときだけ切る
    static func make(raw: URL, seen: URL?, front: URL?, clips: [Clip],
                     overlay: Bool = true, useSeen: Bool = true) async throws -> URL {
        guard let rawLoaded = try await load(raw) else { throw failure("映像がありません") }
        let (rawSource, audioTrack) = rawLoaded
        var seenSource: Source?
        if let seen, useSeen { seenSource = try await load(seen)?.0 }
        // 当てる人の顔（ワイプ）
        var frontSource: Source?
        if let front { frontSource = try await load(front)?.0 }

        let composition = AVMutableComposition()
        guard let rawTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let seenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw failure("合成できません") }
        let audio = audioTrack == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let wipeTrack = frontSource == nil ? nil
            : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        func range(_ from: Double, _ to: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        }

        /// 同じ場面の当てる人の顔を、ワイプの位置に入れる
        func addWipe(_ from: Double, _ to: Double, at: CMTime) {
            guard let frontSource, let wipeTrack, to <= frontSource.duration + 0.5 else { return }
            let end = min(to, frontSource.duration)
            guard end - from > 0.3 else { return }
            try? wipeTrack.insertTimeRange(range(from, end), of: frontSource.track, at: at)
        }

        var pieces: [Piece] = []
        var cursor = CMTime.zero
        for clip in clips {
            let from = max(clip.start, clip.end - before, 0)
            let to = min(clip.end + after, rawSource.duration)
            guard to - from > 0.3 else { continue }
            // 種明かしの前半：当てる人が見ていた画面（声は同じ場面のものを流す）
            if let seenSource, let effect = clip.effect, to <= seenSource.duration + 0.5 {
                let seenTo = min(to, seenSource.duration)
                if seenTo - from > 0.3 {
                    let r = range(from, seenTo)
                    try seenTrack.insertTimeRange(r, of: seenSource.track, at: cursor)
                    if let audioTrack, let audio { try audio.insertTimeRange(r, of: audioTrack, at: cursor) }
                    addWipe(from, seenTo, at: cursor)
                    pieces.append(Piece(caption: "見えていたのは…（\(effect)）", at: cursor.seconds, length: r.duration.seconds, seen: true,
                                        time: CMTimeRange(start: cursor, duration: r.duration)))
                    cursor = cursor + r.duration
                }
            }
            // 後半：実際の演技
            let r = range(from, to)
            try rawTrack.insertTimeRange(r, of: rawSource.track, at: cursor)
            if let audioTrack, let audio { try audio.insertTimeRange(r, of: audioTrack, at: cursor) }
            addWipe(from, to, at: cursor)
            pieces.append(Piece(caption: "お題：\(clip.prompt)　\(clip.outcome)", at: cursor.seconds, length: r.duration.seconds, seen: false,
                                time: CMTimeRange(start: cursor, duration: r.duration)))
            cursor = cursor + r.duration
        }
        guard !pieces.isEmpty else { throw failure("使える場面がありません") }

        // 実際の演技の大きさで描き、見ていた画面は同じ大きさに引き伸ばす
        let renderSize = CGSize(width: rawSource.size.width.rounded(), height: rawSource.size.height.rounded())
        let seenScale: CGAffineTransform = seenSource.map {
            CGAffineTransform(scaleX: renderSize.width / $0.size.width, y: renderSize.height / $0.size.height)
        } ?? .identity
        let instructions: [AVMutableVideoCompositionInstruction] = pieces.map { piece in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = piece.time
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: piece.seen ? seenTrack : rawTrack)
            layer.setTransform(piece.seen ? seenScale : .identity, at: instruction.timeRange.start)
            instruction.layerInstructions = [layer]
            // ワイプは左上に小さく重ねる（BeReal と同じ位置。先頭の指示ほど上に描かれる）
            if let wipeTrack, let frontSource, !wipeTrack.segments.isEmpty {
                let width = renderSize.width * 0.3
                let s = width / frontSource.size.width
                let margin = renderSize.width * 0.03
                let wipe = AVMutableVideoCompositionLayerInstruction(assetTrack: wipeTrack)
                wipe.setTransform(CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: margin, y: margin)),
                                  at: instruction.timeRange.start)
                instruction.layerInstructions = [wipe, layer]
            }
            return instruction
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        // ワイプの枠（左上）。合成の座標は左上が原点、重ねる層は左下が原点
        var wipeFrame: CGRect?
        if let frontSource, let wipeTrack, !wipeTrack.segments.isEmpty {
            let width = renderSize.width * 0.3
            let height = frontSource.size.height * width / frontSource.size.width
            let margin = renderSize.width * 0.03
            wipeFrame = CGRect(x: margin, y: renderSize.height - margin - height, width: width, height: height)
        }
        // シミュレータでは帯の重ね絵（CoreAnimation）の描画で落ちる（OpenGL ES の道で IOSurface を作れない）。
        // 試験では帯なしで書き出す。実機はそのまま
        #if targetEnvironment(simulator)
        let drawOverlay = false
        #else
        let drawOverlay = overlay
        #endif
        if drawOverlay {
            videoComposition.animationTool = await overlayTool(size: renderSize, pieces: pieces, wipe: wipeFrame)
        }

        // 見ていた画面の場面がひとつもなければ、空のトラックを外す
        if seenTrack.segments.isEmpty { composition.removeTrack(seenTrack) }
        if let wipeTrack, wipeTrack.segments.isEmpty { composition.removeTrack(wipeTrack) }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("highlight-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw failure("書き出せません")
        }
        exporter.videoComposition = videoComposition
        try await exporter.export(to: out, as: .mp4)
        // 元の動画を書き出しの終わりまで手放さない
        withExtendedLifetime([rawSource.asset, seenSource?.asset, frontSource?.asset]) {}
        return out
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Highlight", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 場面ごとに、その区間だけ見える帯を重ねる
    @MainActor
    private static func overlayTool(size: CGSize, pieces: [Piece], wipe: CGRect?) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        if let wipe {
            // BeReal の自撮りの窓と同じ、黒い縁
            let border = CALayer()
            border.frame = wipe.insetBy(dx: -size.width * 0.006, dy: -size.width * 0.006)
            border.borderColor = UIColor.black.cgColor
            border.borderWidth = size.width * 0.008
            parent.addSublayer(border)
        }
        // 上の中央にロゴ（BeReal の画面と同じ位置。共有されたとき用）
        let mark = CATextLayer()
        let markHeight = size.height * 0.045
        mark.frame = CGRect(x: 0, y: size.height - markHeight - size.height * 0.025, width: size.width, height: markHeight)
        mark.string = NSAttributedString(string: "OdaiCam.", attributes: [
            .font: UIFont(name: "OdaiCamInter-ExtraBold", size: markHeight * 0.72)
                ?? UIFont.systemFont(ofSize: markHeight * 0.72, weight: .heavy),
            .foregroundColor: UIColor.white,
            .kern: -markHeight * 0.025,
        ])
        mark.alignmentMode = .center
        mark.contentsScale = 2
        mark.shadowOpacity = 0.35
        mark.shadowRadius = 6
        mark.shadowOffset = .zero
        parent.addSublayer(mark)

        // 場面ごとの札（BeReal の丸い札。見えていた画面＝濃い灰色、本当の演技＝白）
        let chipHeight = size.height * 0.055
        for piece in pieces {
            let font = UIFont.systemFont(ofSize: chipHeight * 0.46, weight: .heavy)
            let text = NSAttributedString(string: piece.caption, attributes: [
                .font: font,
                .foregroundColor: piece.seen ? UIColor.white : UIColor.black,
            ])
            let textWidth = min(size.width * 0.9, ceil(text.size().width) + chipHeight * 1.2)
            let chip = CALayer()
            chip.frame = CGRect(x: (size.width - textWidth) / 2, y: size.height * 0.07, width: textWidth, height: chipHeight)
            chip.cornerRadius = chipHeight / 2
            chip.backgroundColor = (piece.seen ? UIColor(white: 0.15, alpha: 0.85) : UIColor.white).cgColor
            let label = CATextLayer()
            let lineHeight = font.lineHeight
            label.frame = CGRect(x: 0, y: (chipHeight - lineHeight) / 2, width: textWidth, height: lineHeight)
            label.string = text
            label.alignmentMode = .center
            label.contentsScale = 2
            chip.addSublayer(label)
            chip.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + piece.at
            show.duration = piece.length
            show.isRemovedOnCompletion = true
            chip.add(show, forKey: "show")
            parent.addSublayer(chip)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}
