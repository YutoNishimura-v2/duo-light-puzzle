import AVFoundation
import SwiftUI

@main
struct CatchLightApp: App {
    var body: some Scene {
        WindowGroup {
            CaptureView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

/// 内側の画面：背面カメラの映像と操作。外側の画面には光を出す
struct CaptureView: View {
    @State private var model = LightModel()
    @State private var camera = Camera()
    @State private var zoom2x = false
    @State private var message: String?
    @State private var flash = false
    @State private var cameraDenied = false
    @State private var cameraReady = false

    var body: some View {
        ZStack {
            CameraPreview(camera: camera, ready: cameraReady).ignoresSafeArea()
            if flash { Color.white.opacity(0.6).ignoresSafeArea() }
            VStack {
                status
                Spacer()
                controls
            }
            .padding()
        }
        // 撮影画面が内側に全画面で出ていて、撮影が動いている間だけ、システムが外側の画面に出す
        .sceneAccessory {
            CameraCaptureAccessory {
                OuterLightView(model: model, shutter: shoot)
            }
        }
        .task { await startCamera() }
        .onDisappear { camera.stop() }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Image(systemName: model.accessoryVisible ? "lightbulb.max.fill" : "lightbulb.slash")
            Text(model.accessoryVisible ? "外側の画面を光らせています" : "外側の画面に出ていません（開いて全画面のとき）")
            Spacer()
            if let message { Text(message).bold() }
        }
        .font(.footnote)
        .padding(10)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay {
            if cameraDenied {
                Text("設定 → CatchLight でカメラを許可してください").padding().background(.red.opacity(0.8), in: Capsule())
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LightShape.allCases) { shape in
                        Button {
                            model.shape = shape
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: shape.symbol).font(.title3)
                                Text(shape.label).font(.caption2)
                            }
                            .frame(width: 62, height: 54)
                            .background(model.shape == shape ? Color.white.opacity(0.3) : Color.black.opacity(0.4),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Label("明るさ", systemImage: "sun.max").labelStyle(.iconOnly)
                Slider(value: $model.level, in: 0.1...1)
                Label("色温度", systemImage: "thermometer.sun").labelStyle(.iconOnly)
                Slider(value: $model.kelvin, in: 2700...7500)
            }
            HStack {
                Label("色", systemImage: "paintpalette").labelStyle(.iconOnly)
                Slider(value: $model.tint, in: 0...1)
                Slider(value: $model.hue, in: 0...1)
                    .tint(Color(hue: model.hue, saturation: 0.85, brightness: 1))
            }
            HStack(spacing: 16) {
                Toggle(isOn: $model.isOn) { Image(systemName: "lightbulb") }.toggleStyle(.button)
                Toggle(isOn: $zoom2x) { Text("2x") }.toggleStyle(.button)
                    .onChange(of: zoom2x) { _, on in camera.setZoom(on ? 2 : 1) }
                Toggle(isOn: $model.subjectShutter) { Image(systemName: "hand.tap") }.toggleStyle(.button)
                Spacer()
                Button(action: shoot) {
                    Circle().fill(.white).frame(width: 64, height: 64)
                        .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 3).padding(4))
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }

    private func shoot() {
        camera.capture(rotationAngle: CameraPreview.PreviewView.latestCaptureAngle)
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            flash = false
        }
    }

    private func startCamera() async {
        camera.onReady = { cameraReady = true }
        camera.onSaved = { text in
            message = text
            Task {
                try? await Task.sleep(for: .seconds(2))
                if message == text { message = nil }
            }
        }
        var granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if !granted { granted = await AVCaptureDevice.requestAccess(for: .video) }
        cameraDenied = !granted
        if granted { camera.start() }
    }
}

/// 外側の画面：被写体に向いた光。被写体が触るとシャッター（切り替え可）
struct OuterLightView: View {
    let model: LightModel
    let shutter: () -> Void

    var body: some View {
        LightView(model: model)
            .contentShape(Rectangle())
            .onTapGesture { if model.subjectShutter { shutter() } }
            .background(BrightnessMaximizer())
            .onAppear { model.accessoryVisible = true }
            .onDisappear { model.accessoryVisible = false }
            .persistentSystemOverlays(.hidden)
    }
}

/// 光として使うので、外側の画面の明るさを最大にする（離れたら戻す）
private struct BrightnessMaximizer: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private weak var screen: UIScreen?
        private var saved: CGFloat = 0.5

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let screen = window?.windowScene?.screen {
                self.screen = screen
                saved = screen.brightness
                screen.brightness = 1
            } else {
                screen?.brightness = saved
            }
        }
    }
}
