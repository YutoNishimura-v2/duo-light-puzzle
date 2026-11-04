@preconcurrency import AVFoundation
import UIKit

/// ラウンドの録画から、お題ごとに「当てる直前の数秒」を切り出してつなぎ、お題の文字を重ねる
enum Highlight {
    struct Clip: Sendable {
        let prompt: String
        let outcome: String
        /// 録画の頭からの秒数
        let start: TimeInterval
        let end: TimeInterval
    }

    /// 1 つのお題から使う長さ。答える直前の山場を中心に取る
    static let before = 4.0
    static let after = 0.8

    static func make(from source: URL, clips: [Clip]) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Highlight", code: 1, userInfo: [NSLocalizedDescriptionKey: "映像がありません"])
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Highlight", code: 2, userInfo: [NSLocalizedDescriptionKey: "合成できません"])
        }
        let compAudio = audioTrack == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        // 切り出す区間と、合成後の動画のどこに置いたか
        var placed: [(clip: Clip, at: Double, length: Double)] = []
        var cursor = 0.0
        for clip in clips {
            let from = max(clip.start, clip.end - before, 0)
            let to = min(clip.end + after, duration)
            guard to - from > 0.3 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                    end: CMTime(seconds: to, preferredTimescale: 600))
            let at = CMTime(seconds: cursor, preferredTimescale: 600)
            try compVideo.insertTimeRange(range, of: videoTrack, at: at)
            if let audioTrack, let compAudio { try compAudio.insertTimeRange(range, of: audioTrack, at: at) }
            placed.append((clip, cursor, to - from))
            cursor += to - from
        }
        guard !placed.isEmpty else {
            throw NSError(domain: "Highlight", code: 3, userInfo: [NSLocalizedDescriptionKey: "使える場面がありません"])
        }

        // 録画の向き（preferredTransform）を反映した大きさで描く
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        videoComposition.animationTool = await overlayTool(size: renderSize, placed: placed)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("highlight-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Highlight", code: 4, userInfo: [NSLocalizedDescriptionKey: "書き出せません"])
        }
        exporter.videoComposition = videoComposition
        try await exporter.export(to: out, as: .mp4)
        return out
    }

    /// お題ごとに、その区間だけ見える帯（お題の文字と ○／パス）を重ねる
    @MainActor
    private static func overlayTool(size: CGSize, placed: [(clip: Clip, at: Double, length: Double)])
        -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let bandHeight = size.height * 0.12
        for item in placed {
            let band = CATextLayer()
            // この座標は左下が原点。下の方に帯を置く
            band.frame = CGRect(x: 0, y: size.height * 0.06, width: size.width, height: bandHeight)
            band.backgroundColor = UIColor(red: 1, green: 0.92, blue: 0.5, alpha: 0.92).cgColor
            band.foregroundColor = UIColor.black.cgColor
            band.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
            band.fontSize = bandHeight * 0.5
            band.alignmentMode = .center
            band.contentsScale = 2
            band.string = "お題：\(item.clip.prompt)　\(item.clip.outcome)"
            band.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + item.at
            show.duration = item.length
            show.isRemovedOnCompletion = true
            band.add(show, forKey: "show")
            parent.addSublayer(band)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}
