@preconcurrency import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 背面カメラでラウンドを丸ごと録画する。Duo を開くと背面カメラは外側の画面と同じ向き（演じる人の方）を向く。
/// できる端末では、内側のカメラ（当てる人の顔）も同時に撮る（カンニングの見張りとワイプ用）。
///
/// 録画は AVAssetWriter で自前で書く。マイクの音声を録画と音声認識の両方に流すため
/// （ムービー出力を使うと、音声を横から取り出せない）。セッションの操作は専用のキューで行う
final class Camera: NSObject, @unchecked Sendable {
    let session: AVCaptureSession
    /// 背面と内側のカメラを同時に使うか（MultiCam に対応し、その組み合わせが許されているとき）
    let usesInnerCamera: Bool
    private let videoOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "camera")
    private var device: AVCaptureDevice?
    private var innerDevice: AVCaptureDevice?
    private var backPort: AVCaptureInput.Port?
    private var innerRotation: AVCaptureDevice.RotationCoordinator?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// しばりをかけた画面（当てる人が見ていたもの）の録画。生の録画と同じ時刻で書く
    private var effectWriter: AVAssetWriter?
    private var effectAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var effectStarted = false
    /// 内側のカメラ（当てる人の顔）の録画。生の録画と同じ時刻で書く
    private var frontWriter: AVAssetWriter?
    private var frontInput: AVAssetWriterInput?
    private var frontStarted = false
    private var writing = false
    /// 生の録画の最初のフレームの時刻。どの録画もここから書き始める
    private var startTime: CMTime?
    /// 試験用の偽カメラ（起動引数 -fakeCamera のときだけ）
    private(set) var fake: FakeCamera?

    /// セッションが動き始めたら呼ぶ（main で呼ぶ）。内側のカメラが動いているか
    var onReady: (@MainActor (Bool) -> Void)?
    /// 録画の最初のフレームの時刻（systemUptime と同じ時計）を知らせる（main で呼ぶ）
    var onRecordingStarted: (@MainActor (TimeInterval) -> Void)?
    /// 録画ファイルができた（main で呼ぶ）。生・しばりをかけた画面・内側のカメラの順
    var onRecordingFinished: (@MainActor (Recordings) -> Void)?
    /// 背面カメラのフレーム（カメラのキューで呼ぶ）。しばりの処理に流す
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    /// 内側のカメラのフレーム（カメラのキューで呼ぶ）。カンニングの見張りに流す
    var onFront: ((CVPixelBuffer) -> Void)?
    /// マイクの音声（カメラのキューで呼ぶ）。音声認識に流す
    var onAudio: ((CMSampleBuffer) -> Void)?

    struct Recordings: Sendable {
        var raw: URL?
        var seen: URL?
        var front: URL?
    }

    override init() {
        usesInnerCamera = FakeCamera.isOn ? false : Self.canUseInnerCamera
        session = usesInnerCamera ? AVCaptureMultiCamSession() : AVCaptureSession()
        super.init()
        fake = FakeCamera.isOn ? FakeCamera(queue: queue) : nil
        // 偽カメラのコマも、本物の背面カメラと同じ処理に流す
        fake?.deliver = { [weak self] in self?.handle($0, isAudio: false) }
        // デモの顔は、内側のカメラと同じ処理に流す
        fake?.deliverFront = { [weak self] in self?.handleFront($0) }
    }

    private static var innerCamera: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInInnerUltraWideCamera], mediaType: .video, position: .unspecified)
            .devices.first
    }

    private static var canUseInnerCamera: Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInInnerUltraWideCamera], mediaType: .video, position: .unspecified)
        return discovery.supportedMultiCamDeviceSets.contains { set in
            set.contains { $0.deviceType == .builtInInnerUltraWideCamera }
                && set.contains { $0.deviceType == .builtInWideAngleCamera && $0.position == .back }
        }
    }

    func start() {
        if let fake {
            queue.async { [self] in
                fake.start()
                // デモでは描いた顔を内側のカメラの代わりに流すので、ワイプを出す
                let inner = FakeCamera.isDemo
                Task { @MainActor [onReady] in onReady?(inner) }
            }
            return
        }
        queue.async { [self] in
            guard session.inputs.isEmpty else {
                if !session.isRunning { session.startRunning() }
                return
            }
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            frontOutput.alwaysDiscardsLateVideoFrames = true
            frontOutput.setSampleBufferDelegate(self, queue: queue)
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            var inner = false
            if usesInnerCamera {
                inner = configureMultiCam()
            } else {
                configureSingle()
            }
            session.startRunning()
            Task { @MainActor [onReady] in onReady?(inner) }
        }
    }

    private func configureSingle() {
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
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        setRotation(90)
        session.commitConfiguration()
    }

    /// 背面・内側・マイクを、つなぐ先を明示して組む。内側をつなげたら true
    private func configureMultiCam() -> Bool {
        guard let ms = session as? AVCaptureMultiCamSession,
              let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return false }
        ms.beginConfiguration()
        defer { ms.commitConfiguration() }

        Self.pickMultiCamFormat(back, minWidth: 1280)
        if let input = try? AVCaptureDeviceInput(device: back), ms.canAddInput(input) {
            ms.addInputWithNoConnections(input)
            device = back
            backPort = input.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: back.position).first
            if ms.canAddOutput(videoOutput) { ms.addOutputWithNoConnections(videoOutput) }
            if let backPort {
                let c = AVCaptureConnection(inputPorts: [backPort], output: videoOutput)
                if ms.canAddConnection(c) { ms.addConnection(c) }
            }
            setRotation(90)
        }

        var innerOK = false
        if let inner = Self.innerCamera {
            Self.pickMultiCamFormat(inner, minWidth: 640)
            if let input = try? AVCaptureDeviceInput(device: inner), ms.canAddInput(input) {
                ms.addInputWithNoConnections(input)
                if ms.canAddOutput(frontOutput) { ms.addOutputWithNoConnections(frontOutput) }
                if let port = input.ports(for: .video, sourceDeviceType: inner.deviceType, sourceDevicePosition: inner.position).first {
                    let c = AVCaptureConnection(inputPorts: [port], output: frontOutput)
                    // 自撮りと同じ見え方にする
                    if c.isVideoMirroringSupported {
                        c.automaticallyAdjustsVideoMirroring = false
                        c.isVideoMirrored = true
                    }
                    if ms.canAddConnection(c) {
                        ms.addConnection(c)
                        innerDevice = inner
                        innerOK = true
                    }
                }
            }
        }

        if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic), ms.canAddInput(input) {
            ms.addInputWithNoConnections(input)
            if ms.canAddOutput(audioOutput) { ms.addOutputWithNoConnections(audioOutput) }
            let ports = input.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified)
            if !ports.isEmpty {
                let c = AVCaptureConnection(inputPorts: ports, output: audioOutput)
                if ms.canAddConnection(c) { ms.addConnection(c) }
            }
        }
        return innerOK && ms.hardwareCost <= 1
    }

    /// 同時に使える形式のうち、minWidth 以上でいちばん小さいもの（負荷を抑える）
    private static func pickMultiCamFormat(_ device: AVCaptureDevice, minWidth: Int32) {
        let formats = device.formats
            .filter { $0.isMultiCamSupported && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= minWidth }
            .sorted { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }
        guard let format = formats.first, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        device.unlockForConfiguration()
    }

    /// MultiCam ではプレビューも自分でつなぐ（main から呼ぶ）
    func connectPreview(_ layer: AVCaptureVideoPreviewLayer) {
        guard usesInnerCamera else { return }
        queue.async { [self] in
            guard let backPort, layer.connection == nil else { return }
            let c = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: layer)
            if session.canAddConnection(c) { session.addConnection(c) }
        }
    }

    /// 内側のカメラの向きを今の持ち方に合わせる（画面の小窓用。main から呼ぶ）
    func alignInner() {
        guard let innerDevice else { return }
        if innerRotation == nil { innerRotation = AVCaptureDevice.RotationCoordinator(device: innerDevice, previewLayer: nil) }
        guard let angle = innerRotation?.videoRotationAngleForHorizonLevelCapture else { return }
        queue.async { [self] in
            if let c = frontOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if let fake { fake.stop() } else { session.stopRunning() }
        }
    }

    func startRecording(rotationAngle: CGFloat) {
        let innerAngle: CGFloat? = {
            guard let innerDevice else { return nil }
            if innerRotation == nil { innerRotation = AVCaptureDevice.RotationCoordinator(device: innerDevice, previewLayer: nil) }
            return innerRotation?.videoRotationAngleForHorizonLevelCapture
        }()
        queue.async { [self] in
            guard !writing else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("round-\(UUID().uuidString).mov")
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                finished(Recordings())
                return
            }
            // フレームは出力の接続で回してから届くので、録画にも向きの変換は要らない
            setRotation(rotationAngle)
            // 偽カメラではカメラの出力が動いていないので、自前の設定を使う
            let video = AVAssetWriterInput(mediaType: .video,
                                           outputSettings: videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
                                               ?? fake?.videoSettings)
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
                finished(Recordings())
                return
            }
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
            startTime = nil
            effectStarted = false
            effectWriter = nil
            effectAdaptor = nil
            frontStarted = false
            frontWriter = nil
            frontInput = nil
            if innerDevice != nil {
                if let innerAngle, let c = frontOutput.connection(with: .video), c.isVideoRotationAngleSupported(innerAngle) {
                    c.videoRotationAngle = innerAngle
                }
                makeFrontWriter()
            } else if fake != nil, FakeCamera.isDemo {
                makeFrontWriter()
            }
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
        // アダプタは書き始める前に作る（後から作ると AVFoundation が例外で落とす）
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard w.startWriting() else { return }
        effectWriter = w
        effectAdaptor = adaptor
    }

    private func makeFrontWriter() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("front-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        // デモではカメラの出力が動いていないので、偽カメラの設定を使う
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: frontOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
                                           ?? fake?.frontVideoSettings)
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else { return }
        w.add(input)
        guard w.startWriting() else { return }
        frontWriter = w
        frontInput = input
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
            frontInput?.markAsFinished()
            guard startTime != nil else {
                writer.cancelWriting()
                effectWriter?.cancelWriting()
                frontWriter?.cancelWriting()
                releaseWriters()
                finished(Recordings())
                return
            }
            let others: [(AVAssetWriter, WritableKeyPath<Recordings, URL?>)] =
                [(effectStarted ? effectWriter : nil, \Recordings.seen), (frontStarted ? frontWriter : nil, \Recordings.front)]
                .compactMap { w, key in w.map { ($0, key) } }
            if !effectStarted { effectWriter?.cancelWriting() }
            if !frontStarted { frontWriter?.cancelWriting() }
            // 書き終わるまでは手元の writer と others が持つので、ここで手放してよい
            // （次のラウンドまで 3 本の書き手と符号化の作業場を残さない）
            releaseWriters()
            let group = DispatchGroup()
            let lock = NSLock()
            var result = Recordings()
            group.enter()
            writer.finishWriting {
                lock.withLock { result.raw = writer.status == .completed ? writer.outputURL : nil }
                group.leave()
            }
            for (w, key) in others {
                group.enter()
                w.finishWriting {
                    lock.withLock { result[keyPath: key] = w.status == .completed ? w.outputURL : nil }
                    group.leave()
                }
            }
            group.notify(queue: queue) { [self] in finished(result) }
        }
    }

    /// 書き手を手放す（カメラのキューで呼ぶ。writing を false にしてから）
    private func releaseWriters() {
        writer = nil
        videoInput = nil
        audioInput = nil
        effectWriter = nil
        effectAdaptor = nil
        frontWriter = nil
        frontInput = nil
    }

    /// できた録画ファイル（ラウンドごと、新しいものが後ろ）。カメラのキューだけで触る
    private var keptRecordings: [[URL]] = []

    private func finished(_ recordings: Recordings) {
        // 一時フォルダに録画がたまらないよう、直近 2 ラウンドぶんだけ残して古いものは消す
        // （いまのラウンドは種明かしを作る元。1 つ前は、まだ書き出しの途中かもしれないので残す）
        let files = [recordings.raw, recordings.seen, recordings.front].compactMap { $0 }
        if !files.isEmpty { keptRecordings.append(files) }
        while keptRecordings.count > 2 {
            for url in keptRecordings.removeFirst() { try? FileManager.default.removeItem(at: url) }
        }
        Task { @MainActor [onRecordingFinished] in onRecordingFinished?(recordings) }
    }

    var currentDevice: AVCaptureDevice? { device }

    /// 保存できたときの文言（結果の画面はこれと比べて、保存できたかを見る）
    static var savedMessage: String { String(localized: "保存しました") }

    /// 動画を写真ライブラリに保存する。結果の文言を返す
    static func saveVideo(_ url: URL) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return String(localized: "写真への保存が許可されていません") }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            return savedMessage
        } catch {
            return String(localized: "保存に失敗しました")
        }
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === frontOutput {
            handleFront(sampleBuffer)
            return
        }
        handle(sampleBuffer, isAudio: output === audioOutput)
    }

    /// 内側のカメラの 1 コマ（カメラのキューで呼ぶ）。デモの描いた顔もここに流す
    func handleFront(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { onFront?(pb) }
        guard writing, let startTime, pts >= startTime, let frontWriter, let frontInput else { return }
        if !frontStarted {
            frontWriter.startSession(atSourceTime: startTime)
            frontStarted = true
        }
        if frontInput.isReadyForMoreMediaData { frontInput.append(sampleBuffer) }
    }

    /// 背面カメラとマイクの 1 コマ（カメラのキューで呼ぶ）。試験用の偽カメラもここに流す
    func handle(_ sampleBuffer: CMSampleBuffer, isAudio: Bool) {
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
        if let fake = camera.fake {
            // 偽カメラでは、最後に流したコマを出す
            view.fakeLayer.contentsGravity = .resizeAspectFill
            view.fakeLayer.masksToBounds = true
            view.layer.addSublayer(view.fakeLayer)
            fake.previewLayer = view.fakeLayer
            return view
        }
        if camera.usesInnerCamera {
            view.previewLayer.setSessionWithNoConnection(camera.session)
        } else {
            view.previewLayer.session = camera.session
        }
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        guard ready else { return }
        camera.connectPreview(view.previewLayer)
        view.attach(device: camera.currentDevice)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        /// 偽カメラのコマを描く層
        let fakeLayer = CALayer()

        override func layoutSubviews() {
            super.layoutSubviews()
            fakeLayer.frame = bounds
        }

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
