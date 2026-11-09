// 偽カメラの動画から、人の型抜き（白が人）の動画を作る。CI の Mac でだけ動かす。
// シミュレータの Vision は人を見つけないので、Mac の Vision で先に型抜きを作り、
// アプリ（シミュレータ）は動画と同じコマの型抜きを受け取って影絵・背景を描く。
//
// 使い方: record-mask IN.mp4 OUT.mp4
// 設定はアプリの personRequest と同じ（balanced・8 ビット）。コマの時刻は元の動画と同じにする。
import AVFoundation
import CoreImage
import Vision

/// input の各コマの型抜きを、元の動画と同じ大きさ・同じ時刻で output に書く。書いたコマ数を返す
private func run(input: URL, output: URL) throws -> Int {
    let asset = AVURLAsset(url: input)
    guard let track = asset.tracks(withMediaType: .video).first else { throw ToolError.noTrack }
    let size = track.naturalSize
    let width = Int(size.width), height = Int(size.height)

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(readerOutput)

    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoAllowFrameReorderingKey: false],
    ])
    writerInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(writerInput)

    guard reader.startReading(), writer.startWriting() else { throw ToolError.start(reader.error ?? writer.error) }
    var started = false
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let context = CIContext()
    var frames = 0
    while let sample = readerOutput.copyNextSampleBuffer() {
        guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
        }
        try VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
        guard let pool = adaptor.pixelBufferPool else { throw ToolError.noPool }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw ToolError.noPool }
        if let mask = request.results?.first?.pixelBuffer {
            let image = CIImage(cvPixelBuffer: mask)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                                 y: CGFloat(height) / image.extent.height))
            context.render(scaled, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: nil)
        } else {
            context.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: out)
        }
        while !writerInput.isReadyForMoreMediaData { usleep(2_000) }
        adaptor.append(out, withPresentationTime: time)
        frames += 1
    }
    writerInput.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw ToolError.finish(writer.error) }
    return frames
}

private enum ToolError: Error {
    case noTrack
    case noPool
    case start(Error?)
    case finish(Error?)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("使い方: record-mask IN.mp4 OUT.mp4")
    exit(2)
}
do {
    let frames = try run(input: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2]))
    print("型抜きの動画 \(frames) コマ → \(arguments[2])")
} catch {
    print("型抜きを作れない: \(error)")
    exit(1)
}
