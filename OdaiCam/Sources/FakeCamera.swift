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
