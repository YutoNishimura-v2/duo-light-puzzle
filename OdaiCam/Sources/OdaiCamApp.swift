import AVFoundation
import AVKit
import SwiftUI

@main
struct OdaiCamApp: App {
    var body: some Scene {
        WindowGroup {
            GuesserView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

/// 内側の画面：当てる人。カメラ越しに演技を見て、○かパスを押す。お題は見えない
struct GuesserView: View {
    @State private var game = Game()
    @State private var camera = Camera()
    @State private var listener = Listener()
    @State private var voiceReady = false
    @State private var cameraReady = false
    @State private var cameraDenied = false
    @State private var editingDeck = false
    @State private var customText = CustomDeck.text
    @State private var message: String?

    var body: some View {
        ZStack {
            CameraPreview(camera: camera, ready: cameraReady).ignoresSafeArea()
            Color.black.opacity(game.phase == .playing ? 0 : 0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                switch game.phase {
                case .menu: menu
                case .countdown(let n): countdown(n)
                case .playing: playing
                case .results: results
                }
            }
            .padding()
        }
        // 撮影画面が内側に全画面で出ていて、撮影が動いている間だけ、システムが外側の画面に出す
        .sceneAccessory {
            CameraCaptureAccessory {
                ActorView(game: game)
            }
        }
        .sheet(isPresented: $editingDeck) { deckEditor }
        .task { await startCamera() }
        .onDisappear { camera.stop() }
    }

    // MARK: 内側の各場面

    private var decks: [Deck] {
        Deck.builtIn + (CustomDeck.deck.map { [$0] } ?? [])
    }

    private var menu: some View {
        VStack(spacing: 16) {
            Text("ジェスチャーお題カメラ").font(.title2.bold())
            Text("Duo を持つ人が当てる人。演じる人は外側の画面のお題を、声を出さずに演じます。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Picker("山札", selection: $game.deck) {
                ForEach(decks) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("時間", selection: $game.roundLength) {
                Text("30 秒").tag(30.0)
                Text("60 秒").tag(60.0)
                Text("90 秒").tag(90.0)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $game.voiceJudge) {
                VStack(alignment: .leading) {
                    Text("声で自動判定")
                    Text(voiceReady ? "当てる人が答えを声に出すと、合っていれば自動で正解" : "この端末では使えません（音声認識の許可と、端末内での日本語の聞き取りが必要）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!voiceReady)
            Button("お題帳を作る（内輪ネタ）", systemImage: "square.and.pencil") { editingDeck = true }
            Button {
                game.startRound()
            } label: {
                Text("スタート").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!cameraReady)
            if cameraDenied { Text("設定でカメラを許可してください").foregroundStyle(.red) }
            Spacer()
        }
    }

    private func countdown(_ n: Int) -> some View {
        VStack {
            Spacer()
            Text("演じる人にお題が出ます").font(.headline)
            Text("\(n)").font(.system(size: 120, weight: .heavy)).monospacedDigit()
            Spacer()
        }
    }

    private var playing: some View {
        VStack {
            HStack {
                Text(String(format: "%.0f", game.remaining.rounded(.up)))
                    .font(.system(size: 44, weight: .heavy)).monospacedDigit()
                Spacer()
                Text("○ \(game.score)").font(.title.bold())
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            Spacer()
            if game.voiceJudge && voiceReady && !game.heard.isEmpty {
                Text("🎤 \(game.heard)")
                    .font(.callout).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            if let last = game.lastAnswer {
                Text("\(last.outcome.rawValue)  \(last.prompt)")
                    .font(.title3.bold())
                    .padding(10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .id(last.prompt)
                    .transition(.opacity)
            }
            HStack(spacing: 16) {
                Button { game.answer(.pass) } label: {
                    Text("パス").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 80)
                }
                .buttonStyle(.bordered).tint(.gray)
                Button { game.answer(.correct) } label: {
                    Text("○ 正解").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 80)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
        }
    }

    private var results: some View {
        VStack(spacing: 12) {
            Text("○ \(game.score) 問").font(.largeTitle.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(game.turns) { t in
                        Text("\(t.outcome?.rawValue ?? "—")  \(t.prompt)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            if game.building {
                ProgressView("ハイライト動画を作っています…")
            } else if let url = game.highlightURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Button("ハイライトを保存", systemImage: "square.and.arrow.down") {
                    Task {
                        message = await Camera.saveVideo(url)
                    }
                }
            } else if let error = game.highlightError {
                Text(error).foregroundStyle(.red)
            }
            if let message { Text(message).font(.footnote.bold()) }
            HStack {
                Button("メニュー") { game.backToMenu() }
                Spacer()
                Button("役を交代してもう一回") {
                    message = nil
                    game.startRound()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var deckEditor: some View {
        NavigationStack {
            TextEditor(text: $customText)
                .padding()
                .navigationTitle("お題帳（1 行に 1 つ）")
                .toolbar {
                    Button("保存") {
                        CustomDeck.text = customText
                        if let deck = CustomDeck.deck { game.deck = deck }
                        editingDeck = false
                    }
                }
        }
    }

    private func startCamera() async {
        game.startRecording = { [camera] in camera.startRecording(rotationAngle: CameraPreview.PreviewView.latestCaptureAngle) }
        game.stopRecording = { [camera] in camera.stopRecording() }
        camera.onReady = { cameraReady = true }
        camera.onRecordingStarted = { game.recordingStarted(at: $0) }
        camera.onRecordingFinished = { game.recordingFinished($0) }
        camera.onAudio = { [listener] in listener.append($0) }
        listener.onHeard = { game.updateHeard($0) }
        listener.onMatch = { game.heardAnswer(for: $0) }
        game.onPrompt = { [listener, game] prompt in
            if let prompt { listener.listen(for: prompt, hints: game.deck.prompts) } else { listener.stop() }
        }
        var granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if !granted { granted = await AVCaptureDevice.requestAccess(for: .video) }
        cameraDenied = !granted
        if granted {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            camera.start()
            voiceReady = await Listener.requestPermission() && listener.isAvailable
            if !voiceReady { game.voiceJudge = false }
        }
    }
}

/// 外側の画面：演じる人。ここにだけお題が出る
struct ActorView: View {
    let game: Game

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.07, blue: 0.12).ignoresSafeArea()
            switch game.phase {
            case .menu:
                VStack(spacing: 12) {
                    Text("🙌").font(.system(size: 72))
                    Text("演じる人はこちら").font(.title.bold())
                    Text("お題がここに出ます。声は出さずに体で！").foregroundStyle(.secondary)
                }
            case .countdown(let n):
                Text("\(n)").font(.system(size: 180, weight: .heavy, design: .rounded)).monospacedDigit()
            case .playing:
                VStack(spacing: 16) {
                    Text(game.current?.prompt ?? "")
                        .font(.system(size: 64, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.3)
                        .lineLimit(2)
                    HStack {
                        Text(String(format: "残り %.0f 秒", game.remaining.rounded(.up)))
                        Spacer()
                        Text("○ \(game.score)")
                    }
                    .font(.title2.bold())
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            case .results:
                VStack(spacing: 12) {
                    Text("🎉").font(.system(size: 72))
                    Text("おつかれさま！").font(.largeTitle.bold())
                    Text("○ \(game.score) 問").font(.title)
                    Text("次は役を交代しよう").foregroundStyle(.secondary)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
    }
}
