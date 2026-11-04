@preconcurrency import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 背面カメラでラウンドを丸ごと録画する。Duo を開くと背面カメラは外側の画面と同じ向き（演じる人の方）を向く。
///
/// 録画は AVAssetWriter で自前で書く。マイクの音声を録画と音声認識の両方に流すため
/// （ムービー出力を使うと、音声を横から取り出せない）。セッションの操作は専用のキューで行う
final class Camera: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "camera")
    private var device: AVCaptureDevice?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// しばりをかけた画面（当てる人が見ていたもの）の録画。生の録画と同じ時刻で書く
    private var effectWriter: AVAssetWriter?
    private var effectAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var effectStarted = false
    private var writing = false
    /// 生の録画の最初のフレームの時刻。どの録画もここから書き始める
    private var startTime: CMTime?

    /// セッションが動き始めたら呼ぶ（main で呼ぶ）
    var onReady: (@MainActor () -> Void)?
    /// 録画の最初のフレームの時刻（systemUptime と同じ時計）を知らせる（main で呼ぶ）
    var onRecordingStarted: (@MainActor (TimeInterval) -> Void)?
    /// 録画ファイルができた（main で呼ぶ）。生の録画と、しばりをかけた画面の録画
    var onRecordingFinished: (@MainActor (URL?, URL?) -> Void)?
    /// 背面カメラのフレーム（カメラのキューで呼ぶ）。しばりの処理に流す
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    /// マイクの音声（カメラのキューで呼ぶ）。音声認識に流す
    var onAudio: ((CMSampleBuffer) -> Void)?

    func start() {
        queue.async { [self] in
            guard session.inputs.isEmpty else {
                if !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                self.device = device
            }
            if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
            }
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            setRotation(90)
            session.commitConfiguration()
            session.startRunning()
            Task { @MainActor [onReady] in onReady?() }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func startRecording(rotationAngle: CGFloat) {
        queue.async { [self] in
            guard !writing else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("round-\(UUID().uuidString).mov")
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                finished(nil)
                return
            }
            // フレームは出力の接続で回してから届くので、録画にも向きの変換は要らない
            setRotation(rotationAngle)
            let video = AVAssetWriterInput(mediaType: .video,
                                           outputSettings: videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov))
            video.expectsMediaDataInRealTime = true
            if writer.canAdd(video) { writer.add(video) }
            var audio: AVAssetWriterInput?
            if let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audio = input
                }
            }
            guard writer.startWriting() else {
                finished(nil)
                return
            }
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
            startTime = nil
            effectStarted = false
            effectWriter = nil
            effectAdaptor = nil
            writing = true
        }
    }

    /// しばりをかけた画面を録画に足す（effects キューから呼ぶ）
    func appendEffect(_ buffer: CVPixelBuffer, time: CMTime) {
        queue.async { [self] in
            guard writing, let startTime, time >= startTime else { return }
            if effectWriter == nil { makeEffectWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
            guard let effectWriter, let effectAdaptor else { return }
            if !effectStarted {
                effectWriter.startSession(atSourceTime: startTime)
                effectStarted = true
            }
            if effectAdaptor.assetWriterInput.isReadyForMoreMediaData {
                effectAdaptor.append(buffer, withPresentationTime: time)
            }
        }
    }

    private func makeEffectWriter(width: Int, height: Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else { return }
        w.add(input)
        guard w.startWriting() else { return }
        effectWriter = w
        effectAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }

    /// カメラのキューで呼ぶ
    private func setRotation(_ angle: CGFloat) {
        if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
    }

    func stopRecording() {
        queue.async { [self] in
            guard writing, let writer else { return }
            writing = false
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            effectAdaptor?.assetWriterInput.markAsFinished()
            guard startTime != nil else {
                writer.cancelWriting()
                effectWriter?.cancelWriting()
                finished(nil)
                return
            }
            let effectWriter = effectStarted ? self.effectWriter : nil
            if !effectStarted { self.effectWriter?.cancelWriting() }
            writer.finishWriting { [self] in
                let raw = writer.status == .completed ? writer.outputURL : nil
                guard let effectWriter else {
                    finished(raw)
                    return
                }
                effectWriter.finishWriting { [self] in
                    finished(raw, effectWriter.status == .completed ? effectWriter.outputURL : nil)
                }
            }
        }
    }

    private func finished(_ raw: URL?, _ seen: URL? = nil) {
        Task { @MainActor [onRecordingFinished] in onRecordingFinished?(raw, seen) }
    }

    var currentDevice: AVCaptureDevice? { device }

    /// 動画を写真ライブラリに保存する。結果の文言を返す
    static func saveVideo(_ url: URL) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return "写真への保存が許可されていません" }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            return "保存しました"
        } catch {
            return "保存に失敗しました"
        }
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isAudio = output === audioOutput
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isAudio {
            onAudio?(sampleBuffer)
        } else if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            onVideo?(pb, pts)
        }
        guard writing, let writer else { return }
        if startTime == nil {
            // 映像の最初のフレームから書き始める
            guard !isAudio else { return }
            writer.startSession(atSourceTime: pts)
            startTime = pts
            let t = pts.seconds
            Task { @MainActor [onRecordingStarted] in onRecordingStarted?(t) }
        }
        if isAudio {
            if let audioInput, audioInput.isReadyForMoreMediaData { audioInput.append(sampleBuffer) }
        } else if let videoInput, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }
}

/// カメラの映像。向きは RotationCoordinator に合わせる
struct CameraPreview: UIViewRepresentable {
    let camera: Camera
    /// セッションが動き始めたら true（向きの合わせ込みを始める）
    let ready: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if ready { view.attach(device: camera.currentDevice) }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        /// 録画の向き（最後に見えていたプレビューの値）
        nonisolated(unsafe) static var latestCaptureAngle: CGFloat = 90

        func attach(device: AVCaptureDevice?) {
            guard let device, coordinator == nil else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.coordinator = coordinator
            apply(coordinator)
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
                DispatchQueue.main.async { self?.apply(c) }
            }
        }

        private func apply(_ c: AVCaptureDevice.RotationCoordinator) {
            previewLayer.connection?.videoRotationAngle = c.videoRotationAngleForHorizonLevelPreview
            PreviewView.latestCaptureAngle = c.videoRotationAngleForHorizonLevelCapture
        }
    }
}
