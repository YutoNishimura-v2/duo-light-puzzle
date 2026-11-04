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
    }

    private struct Source {
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
        return (Source(track: video, size: size, duration: duration), audio)
    }

    static func make(raw: URL, seen: URL?, clips: [Clip]) async throws -> URL {
        guard let rawLoaded = try await load(raw) else { throw failure("映像がありません") }
        let (rawSource, audioTrack) = rawLoaded
        var seenSource: Source?
        if let seen { seenSource = try await load(seen)?.0 }

        let composition = AVMutableComposition()
        guard let rawTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let seenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw failure("合成できません") }
        let audio = audioTrack == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        func range(_ from: Double, _ to: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        }

        var pieces: [Piece] = []
        var cursor = 0.0
        for clip in clips {
            let from = max(clip.start, clip.end - before, 0)
            let to = min(clip.end + after, rawSource.duration)
            guard to - from > 0.3 else { continue }
            // 種明かしの前半：当てる人が見ていた画面（声は同じ場面のものを流す）
            if let seenSource, let effect = clip.effect, to <= seenSource.duration + 0.5 {
                let seenTo = min(to, seenSource.duration)
                if seenTo - from > 0.3 {
                    let at = CMTime(seconds: cursor, preferredTimescale: 600)
                    try seenTrack.insertTimeRange(range(from, seenTo), of: seenSource.track, at: at)
                    if let audioTrack, let audio { try audio.insertTimeRange(range(from, seenTo), of: audioTrack, at: at) }
                    pieces.append(Piece(caption: "見えていたのは…（\(effect)）", at: cursor, length: seenTo - from, seen: true))
                    cursor += seenTo - from
                }
            }
            // 後半：実際の演技
            let at = CMTime(seconds: cursor, preferredTimescale: 600)
            try rawTrack.insertTimeRange(range(from, to), of: rawSource.track, at: at)
            if let audioTrack, let audio { try audio.insertTimeRange(range(from, to), of: audioTrack, at: at) }
            pieces.append(Piece(caption: "お題：\(clip.prompt)　\(clip.outcome)", at: cursor, length: to - from, seen: false))
            cursor += to - from
        }
        guard !pieces.isEmpty else { throw failure("使える場面がありません") }

        // 実際の演技の大きさで描き、見ていた画面は同じ大きさに引き伸ばす
        let renderSize = CGSize(width: rawSource.size.width.rounded(), height: rawSource.size.height.rounded())
        let seenScale: CGAffineTransform = seenSource.map {
            CGAffineTransform(scaleX: renderSize.width / $0.size.width, y: renderSize.height / $0.size.height)
        } ?? .identity
        let instructions: [AVMutableVideoCompositionInstruction] = pieces.map { piece in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range(piece.at, piece.at + piece.length)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: piece.seen ? seenTrack : rawTrack)
            layer.setTransform(piece.seen ? seenScale : .identity, at: instruction.timeRange.start)
            instruction.layerInstructions = [layer]
            return instruction
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        videoComposition.animationTool = await overlayTool(size: renderSize, pieces: pieces)

        // 見ていた画面の場面がひとつもなければ、空のトラックを外す
        if seenTrack.segments.isEmpty { composition.removeTrack(seenTrack) }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("highlight-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw failure("書き出せません")
        }
        exporter.videoComposition = videoComposition
        try await exporter.export(to: out, as: .mp4)
        return out
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Highlight", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 場面ごとに、その区間だけ見える帯を重ねる
    @MainActor
    private static func overlayTool(size: CGSize, pieces: [Piece]) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let bandHeight = size.height * 0.1
        for piece in pieces {
            let band = CATextLayer()
            // この座標は左下が原点。下の方に帯を置く
            band.frame = CGRect(x: 0, y: size.height * 0.06, width: size.width, height: bandHeight)
            band.backgroundColor = (piece.seen
                ? UIColor(white: 0.1, alpha: 0.85)
                : UIColor(red: 1, green: 0.92, blue: 0.5, alpha: 0.92)).cgColor
            band.foregroundColor = (piece.seen ? UIColor.white : UIColor.black).cgColor
            band.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
            band.fontSize = bandHeight * 0.45
            band.alignmentMode = .center
            band.contentsScale = 2
            band.string = piece.caption
            band.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + piece.at
            show.duration = piece.length
            show.isRemovedOnCompletion = true
            band.add(show, forKey: "show")
            parent.addSublayer(band)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}
