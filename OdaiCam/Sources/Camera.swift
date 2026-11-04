@preconcurrency import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 背面カメラでラウンドを丸ごと録画する。Duo を開くと背面カメラは外側の画面と同じ向き（演じる人の方）を向く。
/// セッションの操作は専用のキューで行う
final class Camera: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "camera")
    private var device: AVCaptureDevice?
    /// セッションが動き始めたら呼ぶ（main で呼ぶ）
    var onReady: (@MainActor () -> Void)?
    /// 録画が始まった時刻（systemUptime）を知らせる（main で呼ぶ）
    var onRecordingStarted: (@MainActor (TimeInterval) -> Void)?
    /// 録画ファイルができた（main で呼ぶ）
    var onRecordingFinished: (@MainActor (URL?) -> Void)?

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
            // 笑い声も残す（マイクを断られても映像だけで続ける）
            if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(movie) { session.addOutput(movie) }
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
            guard !movie.isRecording else { return }
            if let connection = movie.connection(with: .video), connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("round-\(UUID().uuidString).mov")
            movie.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async { [self] in
            if movie.isRecording { movie.stopRecording() }
        }
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

extension Camera: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let t = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [onRecordingStarted] in onRecordingStarted?(t) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // 時間切れなどで止まっても、書けたところまでは使える
        let ok = FileManager.default.fileExists(atPath: outputFileURL.path)
        Task { @MainActor [onRecordingFinished] in onRecordingFinished?(ok ? outputFileURL : nil) }
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
