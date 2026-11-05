import AVFoundation
import AVKit
import SwiftUI

@main
struct OdaiCamApp: App {
    init() { CrashLog.start() }

    var body: some Scene {
        WindowGroup {
            GuesserView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

/// 画面の確認用の起動引数（-shot home など）。カメラを使わずに各画面を出す
enum Shot {
    static let name: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-shot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
}

/// 内側の画面：当てる人。iPhone のカメラアプリと同じく、映像を全面に出し、操作はすりガラスで上に重ねる
struct GuesserView: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var game = Game()
    @State private var camera = Camera()
    @State private var listener = Listener()
    @State private var effects = EffectEngine()
    @State private var watch = CheatWatch()
    @State private var voiceReady = false
    @State private var cameraReady = false
    @State private var cameraDenied = false
    /// 内側のカメラが動いているか（カンニングの見張りとワイプに要る）
    @State private var innerReady = false
    /// しばりをかけた画面（当てる人はプレイ中これだけを見る）
    @State private var seenFrame: CGImage?
    @State private var showSettings = false
    @State private var showDecks = false
    @State private var editingDeck = false
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // プレビューは常に下に置く（外側の画面の表示は撮影画面があることが前提）
            if Shot.name == nil {
                CameraPreview(camera: camera, ready: cameraReady).ignoresSafeArea()
            } else {
                SampleScene().ignoresSafeArea()
            }
            switch game.phase {
            case .menu:
                HomeView(game: game, seenFrame: seenFrame, cameraReady: cameraReady, cameraDenied: cameraDenied,
                         showSettings: $showSettings, showDecks: $showDecks)
            case .countdown(let n):
                CountdownView(n: n, game: game)
            case .playing:
                PlayView(game: game, seenFrame: seenFrame, voiceOn: game.voiceJudge && voiceReady)
            case .results:
                ResultsView(game: game)
            }
        }
        .animation(.smooth(duration: 0.35), value: game.phase)
        // 撮影画面が内側に全画面で出ていて、撮影が動いている間だけ、システムが外側の画面に出す
        .sceneAccessory {
            CameraCaptureAccessory {
                ActorView(game: game)
            }
        }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            WelcomeSheet {
                onboarded = true
                Task { await startCamera() }
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(game: game, voiceReady: voiceReady, innerReady: innerReady, editingDeck: $editingDeck) {
                showSettings = false
                // 設定の画面が閉じきってから、ようこそを出す
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    onboarded = false
                }
            }
        }
        .sheet(isPresented: $showDecks) {
            DeckSheet(game: game, editingDeck: $editingDeck)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $editingDeck) { DeckEditor(game: game) }
        .task {
            if let shot = Shot.name {
                onboarded = shot != "welcome"
                cameraReady = true
                voiceReady = true
                innerReady = true
                game.loadPreview(shot)
                if shot == "settings" { showSettings = true }
                if shot == "decks" { showDecks = true }
                return
            }
            if onboarded { await startCamera() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { CrashLog.suspended() } else if phase == .active { CrashLog.resumed() }
        }
        // ホームでは、選んだしばりの見え方をその場で見せる
        .onChange(of: previewEffect) { _, effect in applyPreview(effect) }
        .onChange(of: game.phase) { _, phase in
            CrashLog.mark("画面 \(phase)")
            if phase == .menu { applyPreview(previewEffect) }
        }
        .onDisappear { camera.stop() }
    }

    private var previewEffect: Effect? {
        game.phase == .menu && game.effectsOn ? game.fixedEffect : nil
    }

    private func applyPreview(_ effect: Effect?) {
        guard Shot.name == nil else { return }
        if effect == nil { seenFrame = nil }
        effects.set(effect: effect, promptStart: ProcessInfo.processInfo.systemUptime)
    }

    private func startCamera() async {
        guard !started, Shot.name == nil else { return }
        started = true
        game.startRecording = { [camera, effects] in
            // カウントダウン中はしばりを止める（ホームの見え方の確認を録画に混ぜない）
            effects.set(effect: nil, promptStart: 0)
            camera.startRecording(rotationAngle: CameraPreview.PreviewView.latestCaptureAngle)
        }
        game.stopRecording = { [camera] in camera.stopRecording() }
        camera.onReady = { inner in
            cameraReady = true
            innerReady = inner
            if !inner { game.cheatGuard = false }
            CrashLog.mark("カメラ準備（内側 \(inner ? "あり" : "なし")）")
        }
        camera.onFront = { [watch] in watch.process($0) }
        watch.onCheat = { game.cheated() }
        game.onWatch = { [watch] in watch.setActive($0) }
        camera.onRecordingStarted = { game.recordingStarted(at: $0) }
        camera.onRecordingFinished = { game.recordingFinished($0) }
        camera.onVideo = { [effects] in effects.process($0, time: $1) }
        effects.onPixelBuffer = { [camera] in camera.appendEffect($0, time: $1) }
        effects.onFrame = { seenFrame = $0 }
        game.onEffect = { [effects] effect, start in
            if effect == nil { seenFrame = nil }
            effects.set(effect: effect, promptStart: start)
        }
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

/// 画面の確認用の背景（カメラの代わり）
struct SampleScene: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "figure.arms.open")
                .font(.system(size: 260, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

// MARK: - 初回の説明（Apple 純正アプリの「ようこそ」と同じ形）

struct WelcomeSheet: View {
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    VStack(spacing: 18) {
                        AppMark(size: 84)
                        VStack(spacing: 6) {
                            Text("お題カメラ").font(.largeTitle.bold())
                            Text("Duo の 2 つの画面で遊ぶジェスチャーゲーム")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 56)
                    row("theatermasks.fill", "お題は外側の画面に",
                        "Duo を開いて持つ人が当てる役。外側の画面の前に立つ人だけがお題を見て、声を出さずに演じます。")
                    row("eye.slash.fill", "見えるのは画面越しだけ",
                        "当てる人には、棒人間や影絵に変わった姿しか見えません。顔を上げて直接見るとカンニングで −1 点。")
                    row("waveform", "答えは声に出すだけ",
                        "合っていれば自動で次のお題へ。終わると、見えていた画面と本当の演技を並べた動画ができます。")
                }
                .padding(.horizontal, 36)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 14) {
                Label("声の聞き取りも映像の加工も、すべてこの iPhone の中で行います。", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: finish) {
                    Text("続ける").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.blue)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// アプリの印（アイコンと同じ絵）
struct AppMark: View {
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            Image(systemName: "viewfinder")
                .font(.system(size: size * 0.66, weight: .light))
                .foregroundStyle(.white)
            Text("?")
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - ホーム（カメラアプリの撮影画面と同じ並び）

struct HomeView: View {
    @Bindable var game: Game
    let seenFrame: CGImage?
    let cameraReady: Bool
    let cameraDenied: Bool
    @Binding var showSettings: Bool
    @Binding var showDecks: Bool

    /// 下のモード列（カメラアプリの「写真・ビデオ・ポートレート」と同じ）
    private enum Mode: Hashable {
        case random, fixed(Effect), none

        var title: String {
            switch self {
            case .random: "おまかせ"
            case .fixed(let e): e.label
            case .none: "しばりなし"
            }
        }
    }

    private let modes: [Mode] = [.random] + Effect.allCases.map { .fixed($0) } + [.none]

    private var mode: Mode {
        guard game.effectsOn else { return .none }
        return game.fixedEffect.map { .fixed($0) } ?? .random
    }

    var body: some View {
        ZStack {
            // 選んだしばりをその場でかけて見せる
            if let seenFrame, game.effectsOn, game.fixedEffect != nil {
                Color.black.ignoresSafeArea()
                Image(decorative: seenFrame, scale: 1).resizable().scaledToFill().ignoresSafeArea()
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                hint
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack {
            GlassIconButton(symbol: "gearshape.fill", label: "設定") { showSettings = true }
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    GlassIconButton(symbol: game.voiceJudge ? "waveform" : "waveform.slash", active: game.voiceJudge,
                                    label: "声で自動判定") {
                        game.voiceJudge.toggle()
                    }
                    GlassIconButton(symbol: game.cheatGuard ? "eye.trianglebadge.exclamationmark.fill" : "eye.slash",
                                    active: game.cheatGuard, label: "カンニング禁止") {
                        game.cheatGuard.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .sensoryFeedback(.selection, trigger: game.voiceJudge)
        .sensoryFeedback(.selection, trigger: game.cheatGuard)
    }

    /// いまのモードの説明（カメラアプリの「ナイトモード」などの小さな表示と同じ）
    private var hint: some View {
        let text: String = switch mode {
        case .random: "お題ごとに見え方が変わる"
        case .fixed(let e): e.hint
        case .none: "そのままの映像で当てる"
        }
        return Text(cameraDenied ? "設定アプリでカメラを許可してください" : text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(cameraDenied ? Theme.warning : .white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 14)
            .contentTransition(.opacity)
            .animation(.smooth, value: text)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            timeSelector
            modeStrip
            HStack {
                deckButton
                Spacer()
                ShutterButton(enabled: cameraReady) { game.startRound() }
                Spacer()
                Color.clear.frame(width: 56, height: 56)
            }
            .padding(.horizontal, 30)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    /// 時間（カメラアプリのレンズ切り替え「.5 1x 2」と同じ丸）
    private var timeSelector: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach([30.0, 60.0, 90.0], id: \.self) { t in
                    let selected = game.roundLength == t
                    Button {
                        withAnimation(.snappy) { game.roundLength = t }
                    } label: {
                        Text(selected ? "\(Int(t))秒" : "\(Int(t))")
                            .font(.system(size: selected ? 13 : 12, weight: .semibold))
                            .foregroundStyle(selected ? Theme.accent : .white)
                            .frame(width: selected ? 46 : 34, height: selected ? 46 : 34)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                }
            }
        }
        .sensoryFeedback(.selection, trigger: game.roundLength)
    }

    /// しばりのモード列。選ぶと中央に寄る
    private var modeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(modes, id: \.self) { m in
                        Button {
                            select(m)
                            withAnimation(.snappy) { proxy.scrollTo(m, anchor: .center) }
                        } label: {
                            Text(m.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(m == mode ? Theme.accent : .white)
                        }
                        .buttonStyle(.plain)
                        .id(m)
                    }
                }
                .padding(.horizontal, 160)
            }
            .onAppear { proxy.scrollTo(mode, anchor: .center) }
        }
        .frame(height: 22)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func select(_ m: Mode) {
        switch m {
        case .random:
            game.effectsOn = true
            game.fixedEffect = nil
        case .fixed(let e):
            game.effectsOn = true
            game.fixedEffect = e
        case .none:
            game.effectsOn = false
        }
    }

    /// 山札（カメラアプリの左下の写真の位置）
    private var deckButton: some View {
        Button { showDecks = true } label: {
            VStack(spacing: 5) {
                SymbolTile(symbol: game.deck.symbol, color: game.deck.color, size: 50)
                    .overlay(RoundedRectangle(cornerRadius: 11.5, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                Text(game.deck.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("山札：\(game.deck.title)")
    }
}

// MARK: - 山札をえらぶ（設定アプリと同じ一覧）

struct DeckSheet: View {
    @Bindable var game: Game
    @Binding var editingDeck: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Deck.builtIn + (CustomDeck.deck.map { [$0] } ?? [])) { deck in
                        Button {
                            game.deck = deck
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                SymbolTile(symbol: deck.symbol, color: deck.color)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(deck.title).foregroundStyle(.primary)
                                    Text(deck.prompts.prefix(3).joined(separator: "、") + " など \(deck.prompts.count) 枚")
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if game.deck.id == deck.id {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        dismiss()
                        editingDeck = true
                    } label: {
                        Label(CustomDeck.deck == nil ? "お題帳をつくる" : "お題帳を編集", systemImage: "square.and.pencil")
                    }
                } footer: {
                    Text("友だちの名前や内輪ネタなど、自分たちだけのお題で遊べます。")
                }
            }
            .navigationTitle("山札")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 設定

struct SettingsSheet: View {
    @Bindable var game: Game
    let voiceReady: Bool
    let innerReady: Bool
    @Binding var editingDeck: Bool
    let replayOnboarding: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var crash = CrashLog.report

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $game.voiceJudge) {
                        row("waveform", .blue, "声で自動判定")
                    }
                    .disabled(!voiceReady)
                    Toggle(isOn: $game.cheatGuard) {
                        row("eye.trianglebadge.exclamationmark.fill", .red, "カンニング禁止")
                    }
                    .disabled(!innerReady)
                } footer: {
                    Text(footer)
                }
                Section {
                    Button { editingDeck = true } label: { row("square.and.pencil", .pink, "お題帳を編集") }
                    Button(action: replayOnboarding) { row("questionmark", .gray, "遊び方") }
                }
                Section {
                    LabeledContent { Text("\(game.best) 点").monospacedDigit() } label: { row("trophy.fill", .orange, "自己ベスト") }
                }
                if let crash {
                    Section {
                        Text(crash).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: crash) { Label("この記録を送る", systemImage: "square.and.arrow.up") }
                        Button("消す", role: .destructive) {
                            CrashLog.clear()
                            self.crash = nil
                        }
                    } header: {
                        Text("前回の終了の記録")
                    }
                }
                Section("診断") {
                    Text(MultiCamProbe.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private var footer: String {
        var lines: [String] = []
        lines.append(voiceReady ? "答えを声に出すと、合っていれば自動で正解になります。" : "この iPhone では声の判定を使えません。")
        lines.append(innerReady ? "顔を上げて演じる人を直接見ると −1 点です。" : "この iPhone では 2 つのカメラを同時に使えないため、カンニング禁止は使えません。")
        return lines.joined(separator: "\n")
    }

    private func row(_ symbol: String, _ color: Color, _ title: String) -> some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: symbol, color: color)
            Text(title).foregroundStyle(.primary)
        }
    }
}

struct DeckEditor: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss
    @State private var text = CustomDeck.text
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 280)
                        .focused($focused)
                } footer: {
                    Text("1 行に 1 つ書きます。友だちの名前、職場のネタ、思い出の場面など。")
                }
            }
            .navigationTitle("お題帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") {
                        CustomDeck.text = text
                        if let deck = CustomDeck.deck { game.deck = deck }
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - カウントダウン（カメラアプリのセルフタイマーと同じ）

struct CountdownView: View {
    let n: Int
    let game: Game

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            Text("\(n)")
                .font(.system(size: 200, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(.white)
                .id(n)
                .transition(.asymmetric(insertion: .scale(scale: 1.4).combined(with: .opacity), removal: .opacity))
            VStack {
                Label("演じる人は外側の画面の前へ", systemImage: "theatermasks.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 16)
                Spacer()
                HStack(spacing: 8) {
                    SymbolTile(symbol: game.deck.symbol, color: game.deck.color, size: 22)
                    Text(game.deck.title)
                    Text("・")
                    Text(game.effectsOn ? (game.fixedEffect?.label ?? "おまかせ") : "しばりなし")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 40)
            }
        }
        .animation(.smooth(duration: 0.3), value: n)
    }
}

// MARK: - プレイ中（当てる人）

struct PlayView: View {
    let game: Game
    let seenFrame: CGImage?
    let voiceOn: Bool

    var body: some View {
        ZStack {
            // しばりがあるときは、しばった画面で覆う（本人の映像は見せない）
            if game.current?.effect != nil {
                Color.black.ignoresSafeArea()
                if let seenFrame {
                    Image(decorative: seenFrame, scale: 1).resizable().scaledToFill().ignoresSafeArea()
                } else if Shot.name != nil {
                    SampleStick()
                }
            }
            VStack(spacing: 0) {
                hud
                Spacer()
                toast
                Spacer()
                controls
            }
            cheatBanner
        }
    }

    /// 上の列：点数・残り時間（カメラアプリの録画時間）・いまのしばり
    private var hud: some View {
        HStack {
            Label("\(game.score)", systemImage: "checkmark")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .padding(.horizontal, 14).frame(height: 36)
                .glassEffect(.regular, in: Capsule())
                .animation(.snappy, value: game.score)
            Spacer()
            RecordingTimer(remaining: game.remaining)
            Spacer()
            Group {
                if let effect = game.current?.effect {
                    Label(effect.label, systemImage: effect.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .glassEffect(.regular, in: Capsule())
                        .id(effect)
                        .transition(.blurReplace)
                } else {
                    Color.clear.frame(width: 60, height: 36)
                }
            }
            .animation(.snappy, value: game.current?.effect)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 正解・パスを中央に一瞬だけ出す（音量の表示のような控えめな四角）
    private var toast: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            if let at = game.lastAnswerAt, let last = game.lastAnswer, context.date.timeIntervalSince(at) < 1.1 {
                let t = context.date.timeIntervalSince(at)
                let correct = last.outcome == .correct
                VStack(spacing: 10) {
                    Image(systemName: correct ? "checkmark.circle.fill" : "arrow.uturn.right.circle.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(correct ? Theme.correct : Theme.pass)
                    Text(last.prompt).font(.title3.weight(.semibold))
                    Text(correct ? "正解" : "パス").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(width: 190, height: 190)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .scaleEffect(t < 0.15 ? 0.85 + t : 1)
                .opacity(t > 0.8 ? max(0, 1 - (t - 0.8) / 0.3) : 1)
                .allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if voiceOn {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(Theme.accent)
                    Text(game.heard.isEmpty ? "答えを声に出してください" : game.heard)
                        .lineLimit(1)
                        .foregroundStyle(game.heard.isEmpty ? .secondary : .primary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).frame(height: 40)
                .glassEffect(.regular, in: Capsule())
                .animation(.snappy, value: game.heard)
            }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { game.answer(.pass) } label: {
                        Label("パス", systemImage: "arrow.uturn.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.glass)
                    Button { game.answer(.correct) } label: {
                        Label("正解", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.correct)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// 上から降りてくる赤い知らせ（Dynamic Island の通知のような形）
    private var cheatBanner: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            VStack {
                if let cheat = game.lastCheat, context.date.timeIntervalSince(cheat) < 1.6 {
                    HStack(spacing: 10) {
                        Image(systemName: "eye.trianglebadge.exclamationmark.fill").font(.title3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("カンニング").font(.headline)
                            Text("画面から目を離しました").font(.caption).foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Text("−1").font(Theme.number(24, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular.tint(Theme.warning), in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: game.lastCheat.map { context.date.timeIntervalSince($0) < 1.6 })
            .allowsHitTesting(false)
        }
    }
}

/// 画面の確認用の、しばりをかけた絵の代わり
struct SampleStick: View {
    var body: some View {
        Image(systemName: "figure.dance")
            .font(.system(size: 300, weight: .ultraLight))
            .foregroundStyle(Color(red: 1, green: 0.87, blue: 0.43))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.06, green: 0.07, blue: 0.12))
            .ignoresSafeArea()
    }
}

// MARK: - 結果（フィットネスの「概要」と同じ、黒地に集計カード）

struct ResultsView: View {
    let game: Game
    @State private var shown = 0
    @State private var player: AVPlayer?
    @State private var message: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    scoreCard
                    highlightCard
                    turnsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            actions
        }
        .task {
            if let url = game.highlightURL, player == nil {
                player = AVPlayer(url: url)
                player?.play()
            }
            // 点数を数え上げる
            shown = 0
            for i in 0...max(game.score, 0) {
                withAnimation(.snappy) { shown = i }
                try? await Task.sleep(for: .milliseconds(max(40, 600 / max(game.score, 1))))
            }
        }
        .onChange(of: game.highlightURL) { _, url in
            if let url {
                player = AVPlayer(url: url)
                player?.play()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)).uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("結果").font(.largeTitle.bold())
        }
        .padding(.top, 20)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("スコア").font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(shown)")
                            .font(Theme.number(64, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                        Text("点").font(Theme.number(22, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                if game.isNewBest {
                    Label("自己ベスト", systemImage: "trophy.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
            }
            Divider()
            HStack(spacing: 0) {
                stat("正解", "\(game.correct)", Theme.correct)
                stat("パス", "\(game.turns.filter { $0.outcome == .pass }.count)", Theme.pass)
                stat("カンニング", game.cheats > 0 ? "−\(game.cheats)" : "0", game.cheats > 0 ? Theme.warning : .secondary)
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(Theme.number(28, weight: .semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("種明かし").font(.headline)
                Spacer()
                Text("見えていた画面 → 本当の演技").font(.footnote).foregroundStyle(.secondary)
            }
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let error = game.highlightError {
                    ContentUnavailableView("動画を作れませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("名場面をつないでいます").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let url = game.highlightURL {
                HStack(spacing: 10) {
                    ShareLink(item: url) {
                        Label("共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.glass)
                    Button {
                        Task { message = await Camera.saveVideo(url) }
                    } label: {
                        Label(message ?? "写真に保存", systemImage: message == "保存しました" ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var turnsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("お題").font(.headline).padding(.bottom, 8)
            ForEach(game.turns) { t in
                HStack(spacing: 12) {
                    Image(systemName: t.outcome == .correct ? "checkmark.circle.fill" : "arrow.uturn.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(t.outcome == .correct ? Theme.correct : Theme.pass)
                    Text(t.prompt).font(.body)
                    Spacer()
                    if let effect = t.effect {
                        Label(effect.label, systemImage: effect.symbol)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 11)
                if t.id != game.turns.last?.id { Divider().padding(.leading, 36) }
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    player?.pause()
                    game.backToMenu()
                } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 56, height: 56)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("ホームへ")
                Button {
                    player?.pause()
                    game.startRound()
                } label: {
                    Label("役を交代してもう一回", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.9), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}

// MARK: - 外側の画面（演じる人）

struct ActorView: View {
    let game: Game

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch game.phase {
            case .menu:
                VStack(spacing: 16) {
                    Image(systemName: "theatermasks.fill").font(.system(size: 64)).foregroundStyle(Theme.accent)
                    Text("お題はここに出ます").font(.title.bold())
                    Text("声は出さずに、体だけで演じてください。").font(.body).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(24)
            case .countdown(let n):
                Text("\(n)")
                    .font(.system(size: 220, weight: .thin)).monospacedDigit()
                    .id(n)
                    .transition(.asymmetric(insertion: .scale(scale: 1.4).combined(with: .opacity), removal: .opacity))
            case .playing:
                playing
            case .results:
                VStack(spacing: 10) {
                    Text("おつかれさまでした").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(game.score)").font(Theme.number(120, weight: .bold))
                        Text("点").font(Theme.number(36, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    Text("次は役を交代しましょう").font(.body).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: game.phase)
        .persistentSystemOverlays(.hidden)
    }

    private var playing: some View {
        VStack(spacing: 0) {
            HStack {
                Label(game.deck.title, systemImage: game.deck.symbol)
                Spacer()
                Text(String(format: "0:%02d", Int(game.remaining.rounded(.up))))
                    .monospacedDigit()
                    .foregroundStyle(game.remaining <= 10 ? Theme.warning : .secondary)
            }
            .font(.headline)
            .foregroundStyle(.secondary)
            // 残り時間の細い線
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(game.remaining <= 10 ? Theme.warning : Theme.accent)
                            .frame(width: geo.size.width * max(0, game.remaining / max(game.roundLength, 1)))
                    }
            }
            .frame(height: 4)
            .padding(.top, 10)
            Spacer()
            if let turn = game.current {
                Text(turn.prompt)
                    .font(.system(size: 96, weight: .bold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3)
                    .lineLimit(2)
                    .foregroundStyle(.white)
                    .id(turn.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            Spacer()
            HStack {
                Label("声は出さない", systemImage: "speaker.slash.fill")
                Spacer()
                Label("\(game.score)", systemImage: "checkmark").monospacedDigit()
            }
            .font(.headline)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: game.current?.id)
        .overlay {
            // 当たったら演じる人にも知らせる
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                if let at = game.lastAnswerAt, let last = game.lastAnswer, context.date.timeIntervalSince(at) < 0.9 {
                    let t = context.date.timeIntervalSince(at)
                    let correct = last.outcome == .correct
                    ZStack {
                        Color.black.opacity(0.6)
                        VStack(spacing: 8) {
                            Image(systemName: correct ? "checkmark.circle.fill" : "arrow.uturn.right.circle.fill")
                                .font(.system(size: 90, weight: .semibold))
                                .foregroundStyle(correct ? Theme.correct : Theme.pass)
                            Text(correct ? "正解" : "パス").font(.largeTitle.bold())
                        }
                    }
                    .ignoresSafeArea()
                    .opacity(t > 0.6 ? max(0, 1 - (t - 0.6) / 0.3) : 1)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// 背面と内側のカメラを同時に使えるかを調べる（設定の「診断」に出す）
enum MultiCamProbe {
    static let summary: String = {
        let supported = AVCaptureMultiCamSession.isMultiCamSupported
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInDualWideCamera,
                          .builtInInnerUltraWideCamera, .builtInOuterUltraWideCamera],
            mediaType: .video, position: .unspecified)
        let sets = discovery.supportedMultiCamDeviceSets.map { set in
            set.map { "\($0.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceTypeBuiltIn", with: ""))/\($0.position.rawValue)" }
                .sorted().joined(separator: "+")
        }
        let wanted = discovery.supportedMultiCamDeviceSets.contains { set in
            set.contains { $0.deviceType == .builtInInnerUltraWideCamera } && set.contains { $0.position == .back }
        }
        return "MultiCam: \(supported ? "対応" : "非対応")／背面＋内側: \(wanted ? "可" : "不可")\n" + sets.joined(separator: "\n")
    }()
}
