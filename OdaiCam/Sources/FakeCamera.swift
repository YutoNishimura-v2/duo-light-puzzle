@preconcurrency import AVFoundation
import UIKit
import VideoToolbox

/// 試験用の偽カメラ（起動引数 -fakeCamera YES）。シミュレータにはカメラがないので、動画を流して本物と同じ道を通す。
/// 同梱の fake-camera.mp4（CI でだけ入れる）を繰り返し流す。なければ動く人形をその場で描く。
/// 時刻は本物のカメラと同じ時計（ホストの時計）で付け直す。録画の頭からの秒数がずれないように
final class FakeCamera: @unchecked Sendable {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-fakeCamera")

    /// 1 コマ届けるたびに呼ぶ（カメラのキューで呼ぶ）
    var deliver: ((CMSampleBuffer) -> Void)?
    /// プレビューを描く層（main でだけ触る）
    weak var previewLayer: CALayer?

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pool: CVPixelBufferPool?
    private var count = 0
    /// いま流しているコマの大きさ（録画の設定に使う）
    private(set) var size = CGSize(width: 540, height: 960)

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 録画の設定（本物ではカメラの出力が勧める値を使う）。カメラのキューで呼ぶ
    var videoSettings: [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
    }

    /// カメラのキューで呼ぶ
    func start() {
        guard timer == nil else { return }
        if let url = Bundle.main.url(forResource: "fake-camera", withExtension: "mp4") {
            let asset = AVURLAsset(url: url)
            Task { [self] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
                queue.async { [self] in
                    self.asset = asset
                    self.track = track
                }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        CrashLog.mark("偽カメラ開始（\(Bundle.main.url(forResource: "fake-camera", withExtension: "mp4") == nil ? "描いた人形" : "動画")）")
    }

    /// カメラのキューで呼ぶ
    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let pb = readFrame() ?? drawFrame() else { return }
        size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        deliver?(sample)
        // プレビューは 10 コマ/秒で足りる
        count += 1
        if count % 3 == 0 {
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
            if let cg {
                DispatchQueue.main.async { [self] in previewLayer?.contents = cg }
            }
        }
    }

    /// 同梱の動画から 1 コマ。終わったら頭から読み直す
    private func readFrame() -> CVPixelBuffer? {
        guard let asset, let track else { return nil }
        for _ in 0..<2 {
            if output == nil {
                guard let r = try? AVAssetReader(asset: asset) else { return nil }
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ])
                guard r.canAdd(o) else { return nil }
                r.add(o)
                guard r.startReading() else { return nil }
                reader = r
                output = o
            }
            if let sb = output?.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) { return pb }
            reader?.cancelReading()
            reader = nil
            output = nil
        }
        return nil
    }

    /// 動画がないときの代わり：腕と脚を振る人形
    private func drawFrame() -> CVPixelBuffer? {
        let w = 540, h = 960
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // 壁と床
        ctx.setFillColor(UIColor(red: 0.78, green: 0.74, blue: 0.68, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor(red: 0.45, green: 0.36, blue: 0.28, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 200))
        // 人形（CGContext は左下が原点）
        let t = ProcessInfo.processInfo.systemUptime
        let swing = sin(t * 3)
        let cx = CGFloat(w) / 2 + CGFloat(sin(t * 0.7)) * 60
        let hip = CGPoint(x: cx, y: 420), neck = CGPoint(x: cx, y: 680)
        func limb(_ from: CGPoint, _ angle: Double, _ length: CGFloat) -> CGPoint {
            CGPoint(x: from.x + CGFloat(sin(angle)) * length, y: from.y - CGFloat(cos(angle)) * length)
        }
        ctx.setLineCap(.round)
        ctx.setStrokeColor(UIColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1).cgColor)
        ctx.setLineWidth(56)
        ctx.move(to: hip); ctx.addLine(to: neck); ctx.strokePath()
        ctx.setLineWidth(36)
        for (from, angle, length) in [(hip, 0.35 * swing, 220.0), (hip, -0.35 * swing, 220.0),
                                      (neck, 2.2 + 0.8 * swing, 200.0), (neck, -2.2 + 0.8 * swing, 200.0)] {
            ctx.move(to: from); ctx.addLine(to: limb(from, angle, CGFloat(length))); ctx.strokePath()
        }
        ctx.setFillColor(UIColor(red: 0.93, green: 0.76, blue: 0.62, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 50, y: 700, width: 100, height: 115))
        return pb
    }
}

/// 試験用：ハイライトが作れないとき、どこで失敗するかを部品ごとに試して文にする
enum ExportProbe {
    static func run(raw: URL, seen: URL?, clips: [Highlight.Clip]) async -> String {
        var lines: [String] = []
        for (name, url) in [("生", raw), ("見えていた画面", seen)] {
            guard let url else { lines.append("\(name)：なし"); continue }
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let range = try? await track.load(.timeRange),
               let duration = try? await asset.load(.duration) {
                lines.append("\(name)：\(Int(size.width))x\(Int(size.height)) 長さ \(fmt(duration.seconds)) 映像 \(fmt(range.start.seconds))〜\(fmt(range.end.seconds))")
            } else {
                lines.append("\(name)：読めない")
            }
        }
        lines.append("場面：" + clips.map { "\(fmt($0.start))〜\(fmt($0.end))" }.joined(separator: ","))
        let asset = AVURLAsset(url: raw)
        lines.append("生をそのまま mp4：" + (await export(asset, preset: AVAssetExportPresetHighestQuality, as: .mp4)))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return lines.joined(separator: "／") }
        if let ts = try? await track.load(.naturalTimeScale), let fd = try? await track.load(.minFrameDuration) {
            lines.append("時間の目盛り \(ts)・最短のコマ \(fd.value)/\(fd.timescale)")
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        // 合成：まるごと 1 本／場面ごとに切ってつなぐ
        for cut in [false, true] {
            let comp = AVMutableComposition()
            guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor = CMTime.zero
            var ranges: [CMTimeRange] = []
            let parts: [(Double, Double)] = cut ? clips.map { (max($0.end - 3.5, $0.start, 0), min($0.end + 0.8, duration.seconds)) } : [(0, duration.seconds)]
            for (from, to) in parts {
                let r = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
                do { try t.insertTimeRange(r, of: track, at: cursor) } catch { lines.append("入れられない \((error as NSError).code)"); continue }
                ranges.append(CMTimeRange(start: cursor, duration: r.duration))
                cursor = cursor + r.duration
            }
            let name = cut ? "切って合成" : "まるごと合成"
            lines.append("\(name)（長さ \(String(format: "%.2f", comp.duration.seconds))）：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4)))
            // 自動の指示
            guard let auto = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp) else { continue }
            lines.append("\(name)＋自動の指示（\(auto.instructions.count)）：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4, video: auto)))
            // ハイライトと同じ手書きの指示
            let manual = AVMutableVideoComposition()
            manual.renderSize = auto.renderSize
            manual.frameDuration = CMTime(value: 1, timescale: 30)
            manual.instructions = ranges.map { r in
                let i = AVMutableVideoCompositionInstruction()
                i.timeRange = r
                let l = AVMutableVideoCompositionLayerInstruction(assetTrack: t)
                l.setTransform(.identity, at: r.start)
                i.layerInstructions = [l]
                return i
            }
            lines.append("\(name)＋手書きの指示：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4, video: manual)))
            // 指示を 1 つにまとめる
            let single = AVMutableVideoComposition()
            single.renderSize = auto.renderSize
            single.frameDuration = CMTime(value: 1, timescale: 30)
            let i = AVMutableVideoCompositionInstruction()
            i.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            i.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: t)]
            single.instructions = [i]
            lines.append("\(name)＋指示 1 つ：" + (await export(comp, preset: AVAssetExportPresetHighestQuality, as: .mp4, video: single)))
        }
        return lines.joined(separator: "／")
    }

    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType,
                               video: AVVideoComposition? = nil) async -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).\(type == .mp4 ? "mp4" : "mov")")
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return "作れない" }
        session.videoComposition = video
        do {
            try await session.export(to: out, as: type)
            return "成功"
        } catch {
            let e = error as NSError
            let u = e.userInfo[NSUnderlyingErrorKey] as? NSError
            return "失敗 \(e.code)" + (u.map { " ← \($0.code)" } ?? "")
        }
    }

    private static func fmt(_ t: Double) -> String { String(format: "%.2f", t) }
}
