// 本物の人の動画に、アプリと同じしばり（Sources/Effects.swift）を Mac の本物の Vision でかけて、出来を確かめる道具。
// シミュレータの Vision は人を見つけないので、CI ではこの道具で「人の体についてくるか」を見る。
//
// 使い方: realperson <縦長の動画.mp4> <出力フォルダ> <名前>
//   出力: <名前>-sheet.png（3 つの時刻 × しばり）, <名前>-costume.mp4（着ぐるみ｜実写 を左右に並べた動画）,
//         <名前>-stick.mp4, <名前>.json（見つけた割合・関節の震え）
import AppKit
import AVFoundation
import CoreImage
import Vision

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("使い方: realperson <動画> <出力フォルダ> <名前>")
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let name = args[3]
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 見るしばり（姿を変えるもの 4 つと、背景の代表に宇宙）
let effects: [Effect] = [.stick, .costume, .silhouette, .space, .mosaic]
let sheetTimes: [Double] = [2.0, 5.0, 8.0]

// MARK: 動画を 1 コマずつ読む

let asset = AVURLAsset(url: inputURL)
guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    print("動画のトラックがない: \(inputURL.path)")
    exit(1)
}
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
])
output.alwaysCopiesSampleData = false
reader.add(output)
guard reader.startReading() else {
    print("読めない: \(reader.error?.localizedDescription ?? "?")")
    exit(1)
}

let engines = Dictionary(uniqueKeysWithValues: effects.map { ($0, EffectEngine()) })
let context = CIContext()

struct Stat {
    var frames = 0
    var visible = 0
    /// 型抜きの代わりに骨格から描いた人の形を使ったコマ（影絵・背景）
    var shaped = 0
    /// 1 コマにしばりをかけた時間（ms）。Vision の読み込みが入る始めの warmupFrames コマは数えない
    var ms: [Double] = []
    /// Vision を回した回数の合計（1 コマ 1 回になっているか）
    var visionPasses = 0
}
/// 処理時間に数えない始めのコマ（Vision の学習済みの型を読み込む分）
let warmupFrames = 10

/// 並べた値の q 分位（空なら -1）
func percentile(_ sorted: [Double], _ q: Double) -> Double {
    sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
}
var stats: [Effect: Stat] = [:]
/// 着ぐるみの関節の位置（コマごと、画素）。震えを測る
var jointTrack: [[VNHumanBodyPoseObservation.JointName: CGPoint]] = []
/// 同じ関節の位置（0〜1、アプリの判定と同じ座標）
var unitTrack: [[VNHumanBodyPoseObservation.JointName: CGPoint]] = []
/// 着ぐるみで主役の候補を使ったか・使わなかった理由（全コマ／人形が出なかったコマ）
var decisions: [String: Int] = [:]
var hiddenDecisions: [String: Int] = [:]
/// コマごとの記録（あとで決まりの数字を手元で試すため）
var frameLog: [[String: Any]] = []
var sheetRows: [(t: Double, panels: [(String, CGImage)])] = []
var nextSheet = 0

/// 着ぐるみで人形を出さなかったコマの見本（理由ごと）。元の絵に候補の関節を描いたものと、出した絵の縮小。
/// 誤検出だけを隠したかを、あとで画像で確かめる（<名前>-hidden.png）。
/// 多すぎるときは 1 つおきに間引き、間隔を倍にする（全体から均等に残る）
struct HiddenShots {
    var step = 1
    var seen = 0
    var shots: [(t: Double, raw: CGImage, suit: CGImage)] = []

    mutating func add(t: Double, raw: () -> CGImage?, suit: () -> CGImage?) {
        seen += 1
        guard (seen - 1) % step == 0, let r = raw(), let s = suit() else { return }
        shots.append((t, r, s))
        if shots.count >= 24 {
            shots = shots.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            step *= 2
        }
    }
}
var hiddenShots: [String: HiddenShots] = [:]
/// 着ぐるみで、人形か隠すクマが出たコマの数
var bearFrames = 0
/// 着ぐるみで、見つけた手からクマの手を描いたコマ／人形もクマもぼかしもなく本人が素のまま出たコマ
var handFrames = 0
var rawFrames = 0

// 左右に並べた動画（左：しばり、右：実写）を書く
final class SideBySide {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let size: CGSize
    var started = false

    init?(url: URL, panel: CGSize) {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        size = CGSize(width: panel.width * 2, height: panel.height)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        // 書き始める前に作る（アプリで落ちた原因と同じ決まり）
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        w.add(input)
        writer = w
    }

    func append(left: CGImage, right: CGImage, at time: CMTime) {
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard let pool = adaptor.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            let half = size.width / 2
            ctx.draw(left, in: CGRect(x: 0, y: 0, width: half, height: size.height))
            ctx.draw(right, in: CGRect(x: half, y: 0, width: half, height: size.height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        while !input.isReadyForMoreMediaData { usleep(2000) }
        adaptor.append(pb, withPresentationTime: time)
    }

    func finish() async {
        guard started else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

var costumeVideo: SideBySide?
var stickVideo: SideBySide?
var playableVideos: [Effect: SideBySide] = [:]
var firstTime: Double?

while let sample = output.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if firstTime == nil { firstTime = pts.seconds }
    let t = pts.seconds - (firstTime ?? 0)
    autoreleasepool {
        // 元の絵（しばりと同じ大きさに縮めたもの）
        let raw = CIImage(cvPixelBuffer: pb)
        let long = max(raw.extent.width, raw.extent.height)
        let s = min(1, EffectEngine.longSide / long)
        let small = raw.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let original = context.createCGImage(small, from: small.extent) else { return }

        var images: [Effect: CGImage] = [:]
        for effect in effects {
            guard let engine = engines[effect] else { continue }
            let started = DispatchTime.now().uptimeNanoseconds
            let r = engine.sequenceFrame(effect, source: pb, frameTime: t)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if stats[effect, default: Stat()].frames >= warmupFrames { stats[effect, default: Stat()].ms.append(ms) }
            stats[effect, default: Stat()].frames += 1
            stats[effect, default: Stat()].visionPasses += engine.lastVisionPasses
            if r.visible { stats[effect, default: Stat()].visible += 1 }
            if engine.lastShapeFallback { stats[effect, default: Stat()].shaped += 1 }
            if let image = r.image { images[effect] = image }
            // 影絵の型抜きと人の形の重なり（着ぐるみのあとに回るので、このコマの記録に足す）
            if effect == .silhouette, !frameLog.isEmpty {
                let score = engine.lastShapeScore
                frameLog[frameLog.count - 1]["shape"] = [
                    "fallback": engine.lastShapeFallback,
                    "cover": score.map { ($0.cover * 1000).rounded() / 1000 } ?? -1,
                    "overlap": score.map { ($0.overlap * 1000).rounded() / 1000 } ?? -1,
                ] as [String: Any]
            }
            if effect == .costume {
                let w = CGFloat(original.width), h = CGFloat(original.height)
                jointTrack.append(engine.lastJoints.mapValues { CGPoint(x: $0.x * w, y: $0.y * h) })
                unitTrack.append(engine.lastJoints)
                let decision = engine.lastDecision
                decisions[decision, default: 0] += 1
                // 人形か、人形を出せないときの隠すクマのどちらかが出たコマ（着ぐるみらしく見えたコマ）
                if r.visible || engine.lastCoverDrawn { bearFrames += 1 }
                if engine.lastHandsDrawn > 0 { handFrames += 1 }
                if !r.visible, !engine.lastCoverDrawn, !engine.lastCoverBlurred { rawFrames += 1 }
                if !r.visible {
                    hiddenDecisions[decision, default: 0] += 1
                    let candidate = engine.lastCandidate
                    hiddenShots[decision, default: HiddenShots()].add(
                        t: t, raw: { thumbnail(original, joints: candidate) }, suit: { r.image.flatMap { thumbnail($0, joints: [:]) } })
                }
                func rounded(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
                frameLog.append([
                    "t": (t * 1000).rounded() / 1000,
                    "visible": r.visible,
                    "decision": decision,
                    "biggest_person": rounded(engine.lastBiggestPerson),
                    "people": engine.peopleBoxes.count,
                    "cover": engine.lastCoverDrawn ? "bear" : engine.lastCoverBlurred ? "blur" : "none",
                    "hands": engine.lastHandsDrawn,
                    "boxes": engine.peopleBoxes.map { [rounded($0.minX), rounded($0.minY), rounded($0.width), rounded($0.height)] },
                    "candidate": Dictionary(uniqueKeysWithValues: engine.lastCandidate.map {
                        ($0.key.rawValue.rawValue, [Double($0.value.x), Double($0.value.y)])
                    }),
                ])
            }
        }
        let panel = CGSize(width: original.width, height: original.height)
        if costumeVideo == nil {
            costumeVideo = SideBySide(url: outDir.appendingPathComponent("\(name)-costume.mp4"), panel: panel)
            stickVideo = SideBySide(url: outDir.appendingPathComponent("\(name)-stick.mp4"), panel: panel)
            // 遊べるしばり（Effect.playable）は、本人に見せる比べ動画の元にする
            for effect in Effect.playable {
                playableVideos[effect] = SideBySide(url: outDir.appendingPathComponent("\(name)-\(effect.rawValue).mp4"),
                                                    panel: panel)
            }
        }
        if let c = images[.costume] { costumeVideo?.append(left: c, right: original, at: pts) }
        if let c = images[.stick] { stickVideo?.append(left: c, right: original, at: pts) }
        for (effect, video) in playableVideos {
            if let c = images[effect] { video.append(left: c, right: original, at: pts) }
        }

        if nextSheet < sheetTimes.count, t >= sheetTimes[nextSheet] {
            var panels: [(String, CGImage)] = [("そのまま", original)]
            if let i = images[.stick] { panels.append(("棒人間", i)) }
            if let i = images[.costume] {
                panels.append(("着ぐるみ", i))
                if let o = overlay(i, on: original) { panels.append(("着ぐるみ×実写", o)) }
            }
            if let i = images[.silhouette] { panels.append(("影絵", i)) }
            if let i = images[.space] {
                panels.append(("宇宙", i))
                if let z = headZoom(i, joints: jointTrack.last ?? [:]) { panels.append(("宇宙（頭の拡大）", z)) }
            }
            if let i = images[.mosaic] { panels.append(("モザイク", i)) }
            sheetRows.append((t, panels))
            nextSheet += 1
        }
    }
}
await costumeVideo?.finish()
await stickVideo?.finish()
for video in playableVideos.values { await video.finish() }

// MARK: 画像を作る

/// しばりの絵を実写の上に半分の濃さで重ねる（手足が体からずれていないかを見る）
func overlay(_ top: CGImage, on base: CGImage) -> CGImage? {
    let w = base.width, h = base.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.draw(base, in: rect)
    ctx.setAlpha(0.5)
    ctx.draw(top, in: rect)
    return ctx.makeImage()
}

/// 頭のまわりを 2.5 倍に拡大（髪の縁がガタガタしていないかを見る）。関節がなければ上の真ん中
func headZoom(_ image: CGImage, joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGImage? {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    // 関節は左下が原点、CGImage の切り抜きは左上が原点
    let head = joints[.nose] ?? joints[.neck] ?? CGPoint(x: w / 2, y: h * 0.8)
    let cw = w / 2.5, ch = h / 2.5
    var r = CGRect(x: head.x - cw / 2, y: (h - head.y) - ch / 2, width: cw, height: ch)
    r.origin.x = max(0, min(w - cw, r.origin.x))
    r.origin.y = max(0, min(h - ch, r.origin.y))
    return image.cropping(to: r.integral)
}

func writePNG(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

/// 見出しつきの一覧（行＝時刻、列＝しばり）
func sheet(_ rows: [(t: Double, panels: [(String, CGImage)])]) -> CGImage? {
    guard let first = rows.first?.panels.first?.1 else { return nil }
    let pw = CGFloat(first.width) / 2, ph = CGFloat(first.height) / 2
    let label: CGFloat = 44, gap: CGFloat = 8
    let columns = rows.map(\.panels.count).max() ?? 1
    let W = Int(CGFloat(columns) * (pw + gap) + gap), H = Int(CGFloat(rows.count) * (ph + label + gap) + gap)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .heavy),
                                                .foregroundColor: NSColor.white]
    for (ri, row) in rows.enumerated() {
        // 上の行から並べる（CGContext は左下が原点）
        let top = CGFloat(H) - gap - CGFloat(ri) * (ph + label + gap)
        for (ci, (title, image)) in row.panels.enumerated() {
            let x = gap + CGFloat(ci) * (pw + gap)
            (String(format: "%@  %.0f秒", title, row.t) as NSString).draw(at: CGPoint(x: x + 4, y: top - 32), withAttributes: attrs)
            // 拡大の絵は縦横比が同じなので、同じ枠に入れる
            ctx.draw(image, in: CGRect(x: x, y: top - label - ph, width: pw, height: ph))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

/// 半分の大きさの縮小。joints があれば、関節を赤い点（顔は水色、首は黄色）で描き、首から各関節へ細い線を引く
func thumbnail(_ image: CGImage, joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGImage? {
    let w = image.width / 2, h = image.height / 2
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * CGFloat(w), y: p.y * CGFloat(h)) }
    if let neck = joints[.neck] {
        ctx.setStrokeColor(NSColor.red.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        for p in joints.values { ctx.move(to: px(neck)); ctx.addLine(to: px(p)) }
        ctx.strokePath()
    }
    let face: Set<VNHumanBodyPoseObservation.JointName> = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
    for (joint, p) in joints {
        let color: NSColor = joint == .neck ? .yellow : face.contains(joint) ? .cyan : .red
        let r: CGFloat = joint == .neck ? 6 : 4
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: px(p).x - r, y: px(p).y - r, width: r * 2, height: r * 2))
    }
    return ctx.makeImage()
}

/// 人形を出さなかったコマの一覧：行＝理由（多い順）、各行に均等に選んだ 6 コマ（元＋関節｜出した絵）
func hiddenSheet(_ groups: [String: HiddenShots], counts: [String: Int]) -> CGImage? {
    let reasons = counts.keys.filter { groups[$0]?.shots.isEmpty == false }.sorted { counts[$0]! > counts[$1]! }
    guard let sample = reasons.first.flatMap({ groups[$0]?.shots.first?.raw }) else { return nil }
    let pw = CGFloat(sample.width), ph = CGFloat(sample.height)
    let perRow = 6, gap: CGFloat = 6, label: CGFloat = 26, header: CGFloat = 34
    let W = Int(CGFloat(perRow * 2) * (pw + gap) + gap)
    let rowH = header + label + ph + gap
    let H = Int(CGFloat(reasons.count) * rowH + gap)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .heavy), .foregroundColor: NSColor.white]
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white]
    for (ri, reason) in reasons.enumerated() {
        let shots = groups[reason]!.shots
        let picks = (0..<min(perRow, shots.count)).map { shots[$0 * shots.count / min(perRow, shots.count)] }
        let top = CGFloat(H) - gap - CGFloat(ri) * rowH
        ("理由 \(reason)：\(counts[reason]!) コマ（均等に \(picks.count) コマ。左＝元の絵と骨格の候補、右＝着ぐるみで出した絵）" as NSString)
            .draw(at: CGPoint(x: gap + 4, y: top - header + 6), withAttributes: big)
        for (i, shot) in picks.enumerated() {
            for (j, image) in [shot.raw, shot.suit].enumerated() {
                let x = gap + CGFloat(i * 2 + j) * (pw + gap)
                (String(format: j == 0 ? "%.1f秒 元" : "%.1f秒 着ぐるみ", shot.t) as NSString)
                    .draw(at: CGPoint(x: x + 2, y: top - header - label + 4), withAttributes: small)
                ctx.draw(image, in: CGRect(x: x, y: top - header - label - ph, width: pw, height: ph))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

if let s = sheet(sheetRows) { writePNG(s, outDir.appendingPathComponent("\(name)-sheet.png")) }
if let s = hiddenSheet(hiddenShots, counts: hiddenDecisions) { writePNG(s, outDir.appendingPathComponent("\(name)-hidden.png")) }
for row in sheetRows {
    for (title, image) in row.panels {
        writePNG(image, outDir.appendingPathComponent("\(name)-\(Int(row.t))s-\(title).png"))
    }
}

// MARK: 数字

/// 関節の震え：同じ関節の位置の 2 階差分（p[t+1] − 2p[t] + p[t−1]）の大きさ。動きそのものではなく、コマごとのガタつき
var accel: [Double] = []
if jointTrack.count >= 3 {
    for i in 1..<(jointTrack.count - 1) {
        for (joint, p) in jointTrack[i] {
            guard let a = jointTrack[i - 1][joint], let b = jointTrack[i + 1][joint] else { continue }
            accel.append(Double(hypot(b.x - 2 * p.x + a.x, b.y - 2 * p.y + a.y)))
        }
    }
}
accel.sort()
func pct(_ q: Double) -> Double { accel.isEmpty ? -1 : accel[min(accel.count - 1, Int(Double(accel.count) * q))] }
let framesWithBody = jointTrack.filter { $0.count >= EffectEngine.minJoints }.count
/// 崩れた人形のコマ：人の形として不自然な骨格（横棒・斜めの巨大な人形）を描いたコマの数
/// （plausible は 0〜1 の座標を前提にしているので、画素ではなく unitTrack で判定する）
let brokenFrames = unitTrack.filter { !$0.isEmpty && !EffectEngine.plausible($0) }.count
/// 人形の飛び：前のコマから大きさが 0.6〜1.6 倍を外れた・中心が画面の 2 割より飛んだコマの数（別の人に乗り移った）
var figureJumps = 0
if unitTrack.count >= 2 {
    for i in 1..<unitTrack.count where !unitTrack[i].isEmpty && !unitTrack[i - 1].isEmpty {
        if !EffectEngine.consistent(unitTrack[i], with: unitTrack[i - 1]) { figureJumps += 1 }
    }
}
let framesJSON = try JSONSerialization.data(withJSONObject: frameLog, options: [.sortedKeys])
try framesJSON.write(to: outDir.appendingPathComponent("\(name)-frames.json"))

var summary: [String: Any] = [
    "name": name,
    "frames": jointTrack.count,
    "costume_frames_with_body": framesWithBody,
    "costume_broken_frames": brokenFrames,
    "costume_figure_jumps": figureJumps,
    "costume_decisions": decisions,
    "costume_hidden_by": hiddenDecisions,
    "costume_bear_shown": jointTrack.isEmpty ? 0 : (Double(bearFrames) / Double(jointTrack.count) * 1000).rounded() / 1000,
    "costume_hand_frames": handFrames,
    "costume_raw_frames": rawFrames,
    "joint_jitter_px_median": (pct(0.5) * 10).rounded() / 10,
    "joint_jitter_px_p95": (pct(0.95) * 10).rounded() / 10,
    "frame_height_px": sheetRows.first?.panels.first.map { $0.1.height } ?? 0,
]
for (effect, s) in stats {
    summary["visible_\(effect.rawValue)"] = s.frames > 0 ? (Double(s.visible) / Double(s.frames) * 1000).rounded() / 1000 : 0
    // 1 コマの処理時間（Mac の Vision。iPhone の数字はアプリの設定＞診断に残る）
    let ms = s.ms.sorted()
    summary["ms_\(effect.rawValue)_median"] = (percentile(ms, 0.5) * 10).rounded() / 10
    summary["ms_\(effect.rawValue)_p95"] = (percentile(ms, 0.95) * 10).rounded() / 10
    summary["vision_passes_\(effect.rawValue)"] = s.frames > 0
        ? (Double(s.visionPasses) / Double(s.frames) * 1000).rounded() / 1000 : 0
    if effect == .silhouette || effect == .space {
        summary["shaped_\(effect.rawValue)"] = s.frames > 0 ? (Double(s.shaped) / Double(s.frames) * 1000).rounded() / 1000 : 0
    }
}
let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("\(name).json"))
print(String(data: json, encoding: .utf8) ?? "")
