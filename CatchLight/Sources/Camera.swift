@preconcurrency import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 背面カメラの撮影。セッションの操作は専用のキューで行う
final class Camera: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera")
    private var device: AVCaptureDevice?
    /// 撮影結果を画面に知らせる（main で呼ぶ）
    var onSaved: (@MainActor (String) -> Void)?
    /// セッションが動き始めたら呼ぶ（main で呼ぶ）
    var onReady: (@MainActor () -> Void)?

    func start() {
        queue.async { [self] in
            guard session.inputs.isEmpty else {
                if !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            // Duo を開いたとき、背面カメラは外側の画面と同じ向き（被写体の方）を向く
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                self.device = device
            }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            Task { @MainActor [onReady] in onReady?() }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    /// 1x / 2x
    func setZoom(_ factor: CGFloat) {
        queue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        }
    }

    func capture(rotationAngle: CGFloat) {
        queue.async { [self] in
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    var currentDevice: AVCaptureDevice? { device }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            report("撮影に失敗しました")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
            guard status == .authorized || status == .limited else {
                report("写真への保存が許可されていません")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { [self] ok, _ in
                report(ok ? "保存しました" : "保存に失敗しました")
            }
        }
    }

    private func report(_ message: String) {
        Task { @MainActor [onSaved] in onSaved?(message) }
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
        private(set) var captureAngle: CGFloat = 90

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
            captureAngle = c.videoRotationAngleForHorizonLevelCapture
            PreviewView.latestCaptureAngle = captureAngle
        }

        /// 撮影時の向き（最後に見えていたプレビューの値）
        nonisolated(unsafe) static var latestCaptureAngle: CGFloat = 90
    }
}
