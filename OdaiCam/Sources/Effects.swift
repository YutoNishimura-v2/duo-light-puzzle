@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision
import VideoToolbox

/// 当てる人に見せる映りのしばり。最初は 5 つに絞る
enum Effect: String, CaseIterable, Identifiable, Sendable {
    case stick, silhouette, mosaic, delay, peephole

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stick: "棒人間"
        case .silhouette: "影絵"
        case .mosaic: "モザイク"
        case .delay: "3秒遅れ"
        case .peephole: "のぞき穴"
        }
    }
}

/// 背面カメラのフレームにしばりをかける。重い処理なので専用のキューで、追いつかないフレームは捨てる
final class EffectEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "effects", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var busy = false
    private var effect: Effect?
    private var promptStart: TimeInterval = 0
    /// 3 秒遅れの絵。effects キューだけで触る
    private var history: [(t: TimeInterval, image: CIImage)] = []
    /// しばりが変わったら、次の処理で history を空にする（lock で守る）
    private var clearHistory = false
    private var lastHistory: TimeInterval = 0

    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let personRequest: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    /// しばりをかけた画面（main で呼ぶ）
    var onFrame: (@MainActor (CGImage) -> Void)?
    /// 録画用（effects キューで呼ぶ）。しばりをかけた画面を同じ時刻で書く
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?

    /// 処理する大きさ（長い辺）。Vision も描画もこの大きさで行う
    static let longSide: CGFloat = 960
    static let delaySeconds = 3.0

    func set(effect: Effect?, promptStart: TimeInterval) {
        lock.withLock {
            if self.effect != effect { clearHistory = true }
            self.effect = effect
            self.promptStart = promptStart
        }
    }

    /// カメラのキューから呼ぶ
    func process(_ buffer: CVPixelBuffer, time: CMTime) {
        let (effect, start, skip, clear): (Effect?, TimeInterval, Bool, Bool) = lock.withLock {
            if busy || effect == nil { return (nil, 0, true, false) }
            busy = true
            let clear = clearHistory
            clearHistory = false
            return (self.effect, promptStart, false, clear)
        }
        guard !skip, let effect else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            if clear { history.removeAll() }
            let now = ProcessInfo.processInfo.systemUptime
            let input = Self.downscaled(CIImage(cvPixelBuffer: buffer))
            let output = render(effect, input: input, source: buffer, now: now, elapsed: now - start)
                .cropped(to: input.extent)
            guard let pb = makeBuffer(size: input.extent.size) else { return }
            context.render(output, to: pb)
            onPixelBuffer?(pb, time)
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
            if let cg { Task { @MainActor [onFrame] in onFrame?(cg) } }
        }
    }

    // MARK: しばりごとの絵

    private func render(_ effect: Effect, input: CIImage, source: CVPixelBuffer, now: TimeInterval, elapsed: TimeInterval) -> CIImage {
        let black = CIImage(color: .black).cropped(to: input.extent)
        switch effect {
        case .stick:
            return stickFigure(source: source, size: input.extent.size) ?? black
        case .silhouette:
            return silhouette(source: source, input: input) ?? black
        case .mosaic:
            // 最初は粗く、25 秒かけて細かくなる（早く当てるほど難しい画面で当てたことになる）
            let progress = min(max(elapsed / 25, 0), 1)
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(90 - 78 * progress)
            f.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
            return f.outputImage ?? black
        case .delay:
            return delayed(input, now: now) ?? black.composited(over: black)
        case .peephole:
            // 小さな丸い窓がゆっくりうろつく
            let size = input.extent.size
            let r = min(size.width, size.height) * 0.17
            let center = CGPoint(x: size.width * (0.5 + 0.32 * sin(now * 0.9)),
                                 y: size.height * (0.5 + 0.3 * sin(now * 1.3 + 1)))
            let g = CIFilter.radialGradient()
            g.center = center
            g.radius0 = Float(r * 0.92)
            g.radius1 = Float(r)
            g.color0 = .white
            g.color1 = .black
            let mask = g.outputImage?.cropped(to: input.extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = input
            blend.backgroundImage = black
            blend.maskImage = mask
            return blend.outputImage ?? black
        }
    }

    private func delayed(_ input: CIImage, now: TimeInterval) -> CIImage? {
        // 15 コマ/秒だけ残す（メモリを食いすぎないように、描き終えた絵として持つ）
        if now - lastHistory >= 1.0 / 15, let cg = context.createCGImage(input, from: input.extent) {
            history.append((now, CIImage(cgImage: cg)))
            lastHistory = now
        }
        history.removeAll { now - $0.t > Self.delaySeconds + 0.5 }
        return history.first { now - $0.t <= Self.delaySeconds }?.image
    }

    private func silhouette(source: CVPixelBuffer, input: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: source)
        try? handler.perform([personRequest])
        guard let maskBuffer = personRequest.results?.first?.pixelBuffer else { return nil }
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        mask = mask.transformed(by: CGAffineTransform(scaleX: input.extent.width / mask.extent.width,
                                                      y: input.extent.height / mask.extent.height))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.08)).cropped(to: input.extent)
        blend.backgroundImage = CIImage(color: CIColor(red: 0.96, green: 0.93, blue: 0.85)).cropped(to: input.extent)
        blend.maskImage = mask
        return blend.outputImage
    }

    /// 骨組みだけを描く
    private func stickFigure(source: CVPixelBuffer, size: CGSize) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: source)
        try? handler.perform([bodyRequest])
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let line = max(CGFloat(w) / 45, 6)
        for body in bodyRequest.results ?? [] {
            guard let points = try? body.recognizedPoints(.all) else { continue }
            // Vision の座標は左下が原点の 0〜1。CGContext も左下が原点なのでそのまま掛ける
            func p(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let pt = points[name], pt.confidence > 0.2 else { return nil }
                return CGPoint(x: pt.location.x * CGFloat(w), y: pt.location.y * CGFloat(h))
            }
            let bones: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
                (.neck, .root),
                (.neck, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
                (.neck, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
                (.root, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
                (.root, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
            ]
            ctx.setStrokeColor(UIColor(red: 1, green: 0.87, blue: 0.43, alpha: 1).cgColor)
            ctx.setLineWidth(line)
            for (a, b) in bones {
                guard let pa = p(a), let pb = p(b) else { continue }
                ctx.move(to: pa)
                ctx.addLine(to: pb)
                ctx.strokePath()
            }
            // 頭は首と鼻から丸で描く
            if let neck = p(.neck), let nose = p(.nose) {
                let r = max(hypot(nose.x - neck.x, nose.y - neck.y) * 0.9, line * 2)
                ctx.setLineWidth(line)
                ctx.strokeEllipse(in: CGRect(x: nose.x - r, y: nose.y - r, width: r * 2, height: r * 2))
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: 下ごしらえ

    private static func downscaled(_ image: CIImage) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard long > longSide else { return image }
        let s = longSide / long
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
    }

    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        if pool == nil || poolSize != CGSize(width: width, height: height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = CGSize(width: width, height: height)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}
