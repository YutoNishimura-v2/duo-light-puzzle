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

/// 内側の画面：当てる人。BeReal の撮影画面と同じく、角の丸いファインダーに映像を出し、
/// 左上の小窓に内側のカメラ（当てる人の顔）を出す
struct GuesserView: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var game = Game()
    @State private var camera = Camera()
    @State private var listener = Listener()
    @State private var effects = EffectEngine()
    @State private var watch = CheatWatch()
    @State private var wipeFeed = WipeFeed()
    @State private var voiceReady = false
    @State private var cameraReady = false
    @State private var cameraDenied = false
    /// 内側のカメラが動いているか（カンニングの見張りと小窓に要る）
    @State private var innerReady = false
    /// しばりをかけた画面（当てる人はプレイ中これだけを見る）
    @State private var seenFrame: CGImage?
    /// 左上の小窓に出す、内側のカメラの映像
    @State private var wipe: CGImage?
    @State private var showSettings = false
    @State private var showDecks = false
    @State private var editingDeck = false
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // プレビューは常に下に置く（外側の画面の表示は撮影画面があることが前提）。
            // 見せるのはファインダーの枠の中だけで、外は黒で覆う
            if Shot.name == nil {
                CameraPreview(camera: camera, ready: cameraReady).ignoresSafeArea()
            } else {
                SampleScene().ignoresSafeArea()
            }
            switch game.phase {
            case .menu:
                HomeView(game: game, seenFrame: seenFrame, wipe: wipe, cameraReady: cameraReady, cameraDenied: cameraDenied,
                         innerReady: innerReady, voiceReady: voiceReady, showSettings: $showSettings, showDecks: $showDecks)
            case .countdown(let n):
                CountdownView(n: n, game: game, wipe: wipe)
            case .playing:
                PlayView(game: game, seenFrame: seenFrame, wipe: wipe, voiceOn: game.voiceJudge && voiceReady)
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
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            WelcomeView {
                onboarded = true
                Task { await startCamera() }
            }
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
                .presentationDetents([.large])
                .presentationBackground(Color(white: 0.06))
                .presentationCornerRadius(36)
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
        camera.onReady = { [camera] inner in
            cameraReady = true
            innerReady = inner
            if inner { camera.alignInner() } else { game.cheatGuard = false }
            CrashLog.mark("カメラ準備（内側 \(inner ? "あり" : "なし")）")
        }
        camera.onFront = { [watch, wipeFeed] in
            watch.process($0)
            wipeFeed.process($0)
        }
        wipeFeed.onImage = { wipe = $0 }
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
        if FakeCamera.isOn {
            // 試験用：許可を求めず、偽のカメラだけ動かす（声の判定は使わない）
            game.voiceJudge = false
            camera.start()
            return
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
            LinearGradient(colors: [Color(red: 0.55, green: 0.6, blue: 0.68), Color(red: 0.22, green: 0.2, blue: 0.2)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "figure.arms.open")
                .font(.system(size: 260, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// 画面の確認用の、内側のカメラの代わり
struct SampleFace: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.78, green: 0.62, blue: 0.5), Color(red: 0.35, green: 0.25, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "person.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.5))
                .offset(y: 14)
        }
    }
}

// MARK: - 撮影画面の部品（BeReal と同じ、角の丸いファインダーと左上の小窓）

/// ファインダー。中身は角を丸めて切り、外側（左右の余白と四隅）は黒で覆う。
/// 下に敷いた全面のカメラのプレビューが、枠の中だけ見える
struct Viewfinder<Content: View>: View {
    let wipe: CGImage?
    var showWipe = true
    @ViewBuilder let content: Content

    private static var inset: CGFloat { 8 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shape = RoundedRectangle(cornerRadius: Theme.viewfinderRadius, style: .continuous)
            ZStack(alignment: .topLeading) {
                content
                    .frame(width: width, height: geo.size.height)
                if showWipe, wipe != nil || Shot.name != nil {
                    WipeView(image: wipe)
                        .frame(width: width * 0.3, height: width * 0.4)
                        .padding(12)
                        .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .frame(width: width, height: geo.size.height)
            .clipShape(shape)
            .contentShape(shape)
        }
        .padding(.horizontal, Self.inset)
        .overlay {
            FinderCutout(inset: Self.inset, radius: Theme.viewfinderRadius)
                .fill(.black, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
        }
    }
}

/// 枠の外だけを塗る形（全体の四角から、角の丸い枠をくり抜く）
struct FinderCutout: Shape {
    let inset: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect.insetBy(dx: inset, dy: 0), cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

/// 左上の小窓（BeReal の自撮りの窓。黒い細い縁で角を丸める）
struct WipeView: View {
    let image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.wipeRadius, style: .continuous)
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    SampleFace()
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.black, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// しばりをかけた画面。画像そのものを並べると、はみ出した分だけ枠が広がり、
/// 上に重ねたボタンが画面の外に押し出される。黒い面の重ね絵にして、枠の大きさは保つ
struct EffectFrame: View {
    let image: CGImage

    var body: some View {
        Color.black
            .overlay {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
            .clipped()
    }
}

/// 画面の確認用の、しばりをかけた絵の代わり
struct SampleStick: View {
    var body: some View {
        Image(systemName: "figure.dance")
            .font(.system(size: 260, weight: .ultraLight))
            .foregroundStyle(Color(red: 1, green: 0.87, blue: 0.43))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.06, green: 0.07, blue: 0.12))
    }
}

/// 上の列の下に出る小さな行（BeReal の撮影画面の「01:05」）
struct UnderBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(height: 26)
            .padding(.bottom, 10)
    }
}

// MARK: - 初回の説明（BeReal の「Welcome to BeReal.」と同じ並び）

struct WelcomeView: View {
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ようこそ").font(Theme.bold(17)).foregroundStyle(Theme.secondary)
                        Wordmark(size: 46)
                        Text("Duo の 2 つの画面で遊ぶ、声を出さないジェスチャーゲーム。")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 70)
                    .padding(.bottom, 6)
                    row("theatermasks", "お題は外側の画面に",
                        "Duo を開いて持つ人が当てる役。外側の画面の前に立つ人だけがお題を見て、声を出さずに演じます。")
                    row("eye.slash", "見えるのは画面越しだけ",
                        "当てる人には、棒人間や影絵に変わった姿しか見えません。顔を上げて直接見るとカンニングで −1 点。")
                    row("waveform", "答えは声に出すだけ",
                        "合っていれば自動で次のお題へ。")
                    row("play.rectangle", "最後に種明かし",
                        "見えていた画面と本当の演技を並べた動画ができます。そのまま友だちに送れます。")
                }
                .padding(.horizontal, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 14) {
                Text("声の聞き取りも映像の加工も、すべてこの iPhone の中で行います。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                Button("はじめる", action: finish)
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.bold(17)).foregroundStyle(.white)
                Text(text).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - ホーム（BeReal の撮影画面と同じ並び）

struct HomeView: View {
    @Bindable var game: Game
    let seenFrame: CGImage?
    let wipe: CGImage?
    let cameraReady: Bool
    let cameraDenied: Bool
    let innerReady: Bool
    let voiceReady: Bool
    @Binding var showSettings: Bool
    @Binding var showDecks: Bool

    /// シャッターの下のモード（BeReal の「ROULETTE　カメラ」と同じ文字の切り替え）
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
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar {
                    BarButton(symbol: "gearshape", label: "設定") { showSettings = true }
                } trailing: {
                    Button { showDecks = true } label: {
                        Avatar(text: game.deck.initial, size: 34).padding(5)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("山札：\(game.deck.title)")
                }
                UnderBar {
                    TimerText(remaining: game.roundLength)
                }
            }
            .background(Color.black.ignoresSafeArea(edges: .top))

            Viewfinder(wipe: wipe, showWipe: innerReady) {
                ZStack {
                    // 選んだしばりをその場でかけて見せる
                    if let seenFrame, game.effectsOn, game.fixedEffect != nil {
                        EffectFrame(image: seenFrame)
                    }
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            deckChip
                        }
                        Spacer()
                        if cameraDenied {
                            Chip(symbol: "exclamationmark.triangle.fill", text: "設定アプリでカメラを許可してください")
                        } else {
                            Chip(symbol: modeSymbol, text: modeHint)
                                .contentTransition(.opacity)
                                .animation(.smooth, value: modeHint)
                        }
                        timeChips.padding(.top, 10)
                    }
                    .padding(12)
                }
            }

            VStack(spacing: 12) {
                HStack {
                    toggle(on: game.voiceJudge, onSymbol: "waveform", offSymbol: "waveform.slash",
                           label: "声で自動判定", enabled: voiceReady) { game.voiceJudge.toggle() }
                    Spacer()
                    ShutterButton(enabled: cameraReady) { game.startRound() }
                    Spacer()
                    toggle(on: game.cheatGuard, onSymbol: "eye", offSymbol: "eye.slash",
                           label: "カンニング禁止", enabled: innerReady) { game.cheatGuard.toggle() }
                }
                .padding(.horizontal, 44)
                modeStrip
            }
            .padding(.top, 16)
            .padding(.bottom, 6)
            .background(Color.black.ignoresSafeArea(edges: .bottom))
        }
        .sensoryFeedback(.selection, trigger: game.voiceJudge)
        .sensoryFeedback(.selection, trigger: game.cheatGuard)
    }

    /// 右上の札（BeReal の「BTS Off」の位置）。押すと山札を選ぶ
    private var deckChip: some View {
        ChipButton(symbol: game.deck.symbol, text: "\(game.deck.title)  \(game.deck.prompts.count)",
                   label: "山札をえらぶ") { showDecks = true }
    }

    private var modeSymbol: String {
        switch mode {
        case .random: "shuffle"
        case .fixed(let e): e.symbol
        case .none: "eye"
        }
    }

    private var modeHint: String {
        switch mode {
        case .random: "お題ごとに見え方が変わる"
        case .fixed(let e): e.hint
        case .none: "そのままの映像で当てる"
        }
    }

    /// 時間（BeReal の「1.0x」と同じ黒い丸）
    private var timeChips: some View {
        HStack(spacing: 6) {
            ForEach([30.0, 60.0, 90.0], id: \.self) { t in
                let selected = game.roundLength == t
                Button {
                    withAnimation(.snappy) { game.roundLength = t }
                } label: {
                    Text(selected ? "\(Int(t))秒" : "\(Int(t))")
                        .font(.system(size: selected ? 13 : 12, weight: .bold))
                        .foregroundStyle(selected ? .white : Theme.secondary)
                        .frame(width: selected ? 44 : 34, height: selected ? 44 : 34)
                        .background(.black.opacity(selected ? 0.85 : 0.55), in: Circle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .sensoryFeedback(.selection, trigger: game.roundLength)
    }

    /// シャッターの左右の白い記号（BeReal のフラッシュと切り替え）
    private func toggle(on: Bool, onSymbol: String, offSymbol: String, label: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(enabled ? .white : Theme.tertiary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "オン" : "オフ")
    }

    /// しばりのモード列。選ぶと中央に寄る
    private var modeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 26) {
                    ForEach(modes, id: \.self) { m in
                        Button {
                            select(m)
                            withAnimation(.snappy) { proxy.scrollTo(m, anchor: .center) }
                        } label: {
                            Text(m.title)
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(m == mode ? .white : Theme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .id(m)
                    }
                }
                .padding(.horizontal, 150)
            }
            .onAppear { proxy.scrollTo(mode, anchor: .center) }
        }
        .frame(height: 24)
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
}

// MARK: - 山札をえらぶ（BeReal の「位置設定」のシートと同じ。選んだものだけ白いカード）

struct DeckSheet: View {
    @Bindable var game: Game
    @Binding var editingDeck: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("山札").font(Theme.bold(22))
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(white: 0.2), in: Circle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("閉じる")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Deck.builtIn + (CustomDeck.deck.map { [$0] } ?? [])) { deck in
                        let selected = game.deck.id == deck.id
                        Button {
                            game.deck = deck
                            dismiss()
                        } label: {
                            card(symbol: deck.symbol, title: deck.title,
                                 text: deck.prompts.prefix(3).joined(separator: "、") + " など \(deck.prompts.count) 枚",
                                 selected: selected)
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Button {
                        dismiss()
                        editingDeck = true
                    } label: {
                        card(symbol: CustomDeck.deck == nil ? "plus" : "square.and.pencil",
                             title: CustomDeck.deck == nil ? "お題帳をつくる" : "お題帳を編集",
                             text: "友だちの名前や内輪ネタで遊ぶ", selected: false)
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(.white)
    }

    private func card(symbol: String, title: String, text: String, selected: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.bold(19))
                Text(text).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color(white: 0.4) : Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(selected ? Color.white : Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - 設定（BeReal の設定と同じ、黒地に濃い灰色の行と白い記号）

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
                    Toggle(isOn: $game.voiceJudge) { row("waveform", "声で自動判定") }
                        .disabled(!voiceReady)
                        .tint(.green)
                    Toggle(isOn: $game.cheatGuard) { row("eye", "カンニング禁止") }
                        .disabled(!innerReady)
                        .tint(.green)
                } footer: {
                    Text(footer)
                }
                .listRowBackground(Theme.surface)
                Section {
                    Button { editingDeck = true } label: { link("square.and.pencil", "お題帳を編集") }
                        .buttonStyle(.plain)
                    Button(action: replayOnboarding) { link("questionmark.circle", "遊び方") }
                        .buttonStyle(.plain)
                }
                .listRowBackground(Theme.surface)
                Section {
                    LabeledContent {
                        Text("\(game.best) 点").monospacedDigit().foregroundStyle(Theme.secondary)
                    } label: { row("trophy", "自己ベスト") }
                }
                .listRowBackground(Theme.surface)
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
                    .listRowBackground(Theme.surface)
                }
                Section("診断") {
                    Text(MultiCamProbe.summary).font(.caption.monospaced()).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                }
                .listRowBackground(Theme.surface)
                Section {
                    VStack(spacing: 4) {
                        Wordmark(size: 20)
                        Text("お題カメラ").font(.footnote).foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .tint(.white)
        .presentationBackground(.black)
    }

    private var footer: String {
        var lines: [String] = []
        lines.append(voiceReady ? "答えを声に出すと、合っていれば自動で正解になります。" : "この iPhone では声の判定を使えません。")
        lines.append(innerReady ? "顔を上げて演じる人を直接見ると −1 点です。" : "この iPhone では 2 つのカメラを同時に使えないため、カンニング禁止は使えません。")
        return lines.joined(separator: "\n")
    }

    /// 右に「>」のつく行
    private func link(_ symbol: String, _ title: String) -> some View {
        HStack {
            row(symbol, title)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func row(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
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
            VStack(alignment: .leading, spacing: 12) {
                Text("1 行に 1 つ書きます。友だちの名前、職場のネタ、思い出の場面など。")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                TextEditor(text: $text)
                    .font(.system(size: 19, weight: .semibold))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .focused($focused)
            }
            .padding(16)
            .background(Color.black)
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
        .tint(.white)
        .presentationBackground(.black)
    }
}

// MARK: - カウントダウン（ファインダーに大きな数字。シャッターの輪が満ちていく）

struct CountdownView: View {
    let n: Int
    let game: Game
    let wipe: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar { Color.clear.frame(width: 44) } trailing: { Color.clear.frame(width: 44) }
                UnderBar { TimerText(remaining: game.roundLength) }
            }
            .background(Color.black.ignoresSafeArea(edges: .top))

            Viewfinder(wipe: wipe, showWipe: wipe != nil) {
                ZStack {
                    Color.black.opacity(0.35)
                    Text("\(n)")
                        .font(.system(size: 220, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 20)
                        .id(n)
                        .transition(.asymmetric(insertion: .scale(scale: 1.3).combined(with: .opacity), removal: .opacity))
                    VStack {
                        Spacer()
                        Chip(symbol: "theatermasks", text: "演じる人は外側の画面の前へ")
                    }
                    .padding(14)
                }
            }

            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color(white: 0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: CGFloat(4 - n) / 3)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 78, height: 78)
                .animation(.easeInOut(duration: 0.8), value: n)
                Text("\(game.deck.title) ・ \(game.effectsOn ? (game.fixedEffect?.label ?? "おまかせ") : "しばりなし")")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(height: 24)
            }
            .padding(.top, 19)
            .padding(.bottom, 6)
            .background(Color.black.ignoresSafeArea(edges: .bottom))
        }
        .animation(.smooth(duration: 0.3), value: n)
    }
}

// MARK: - プレイ中（当てる人）

struct PlayView: View {
    let game: Game
    let seenFrame: CGImage?
    let wipe: CGImage?
    let voiceOn: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar { Color.clear.frame(width: 44) } trailing: { Color.clear.frame(width: 44) }
                UnderBar { TimerText(remaining: game.remaining) }
            }
            .background(Color.black.ignoresSafeArea(edges: .top))

            Viewfinder(wipe: wipe, showWipe: wipe != nil || Shot.name != nil) {
                ZStack {
                    // しばりがあるときは、しばった画面で覆う（本人の映像は見せない）
                    if game.current?.effect != nil {
                        if let seenFrame {
                            EffectFrame(image: seenFrame)
                        } else if Shot.name != nil {
                            SampleStick()
                        } else {
                            // 最初のしばりの画面が届くまでは、本人の映像を見せない
                            Color.black
                        }
                    }
                    VStack {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            if let effect = game.current?.effect {
                                Chip(symbol: effect.symbol, text: effect.label)
                                    .id(effect)
                                    .transition(.blurReplace)
                            }
                            Chip(symbol: "checkmark", text: "\(game.score)")
                                .contentTransition(.numericText())
                        }
                        .animation(.snappy, value: game.current?.effect)
                        .animation(.snappy, value: game.score)
                        Spacer()
                        if voiceOn {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                Text(game.heard.isEmpty ? "答えを声に出して" : "「\(game.heard)」")
                                    .lineLimit(1)
                            }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(game.heard.isEmpty ? Theme.secondary : .white)
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(Theme.chip, in: Capsule())
                            .animation(.snappy, value: game.heard)
                        }
                    }
                    .padding(12)
                }
            }

            HStack(spacing: 12) {
                Button { game.answer(.pass) } label: { Text("パス") }
                    .buttonStyle(PillButtonStyle(primary: false, height: 60, fontSize: 19))
                Button { game.answer(.correct) } label: {
                    HStack(spacing: 6) {
                        Text("正解")
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy))
                    }
                }
                .buttonStyle(PillButtonStyle(height: 60, fontSize: 19))
                .accessibilityLabel("正解")
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 26)
            .background(Color.black.ignoresSafeArea(edges: .bottom))
        }
        .overlay(alignment: .top) { notices }
    }

    /// 正解・パス・カンニングは、BeReal の通知の形で上から降ろす
    private var notices: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let now = context.date
            let cheat = game.lastCheat.map { now.timeIntervalSince($0) < 1.6 } ?? false
            let answer = game.lastAnswerAt.map { now.timeIntervalSince($0) < 1.2 } ?? false
            VStack {
                if cheat {
                    NoticeBanner(title: "⚠️ カンニング ⚠️", message: "画面から目を離しました", trailing: "−1", tint: Theme.warning)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if answer, let last = game.lastAnswer {
                    let correct = last.outcome == .correct
                    NoticeBanner(title: correct ? "正解！" : "パス", message: last.prompt, trailing: correct ? "+1" : nil)
                        .id(game.lastAnswerAt)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: cheat)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: answer)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 結果（BeReal の投稿と同じ。丸い写真・名前・大きなカード・コメントの並び）

struct ResultsView: View {
    let game: Game
    @State private var shown = 0
    @State private var player: AVPlayer?
    @State private var message: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar {
                    BarButton(symbol: "xmark", label: "ホームへ") {
                        player?.pause()
                        game.backToMenu()
                    }
                } trailing: {
                    Color.clear.frame(width: 44)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        post
                        shareRow
                        caption
                        turns
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 130)
                }
                .scrollIndicators(.hidden)
            }
            again
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

    /// 投稿の頭（丸い写真・名前・いつ）
    private var header: some View {
        HStack(spacing: 10) {
            Avatar(text: game.deck.initial, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(game.deck.title) ・ \(Int(game.roundLength))秒").font(Theme.bold(15))
                Text(Date.now.formatted(.dateTime.month().day().hour().minute())).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(shown)").font(Theme.heavy(30)).contentTransition(.numericText())
                Text("点").font(Theme.heavy(16))
            }
        }
        .padding(.horizontal, 4)
    }

    /// 種明かしの動画（BeReal の写真のカード。できるまでは「投稿して表示」のようにぼかす）
    private var post: some View {
        ZStack {
            Color(white: 0.08)
            if let player {
                VideoPlayer(player: player)
            } else if let error = game.highlightError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .semibold))
                    Text("動画を作れませんでした").font(Theme.bold(17))
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
            } else {
                SampleScene().blur(radius: 30).opacity(0.6)
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 34, weight: .semibold))
                    Text("種明かしをつくっています").font(Theme.bold(17))
                    Text("見えていた画面と、本当の演技を並べています").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    ProgressView().tint(.white).padding(.top, 4)
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// 共有の丸いボタンの列（BeReal の「Share via・Instagram・メッセージ」）
    @ViewBuilder
    private var shareRow: some View {
        if let url = game.highlightURL {
            HStack(spacing: 22) {
                ShareLink(item: url) {
                    roundIcon("square.and.arrow.up", "共有")
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("共有")
                Button {
                    Task { message = await Camera.saveVideo(url) }
                } label: {
                    roundIcon(message == "保存しました" ? "checkmark" : "square.and.arrow.down", message ?? "写真に保存")
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("写真に保存")
                Spacer()
            }
            .padding(.horizontal, 6)
        }
    }

    private func roundIcon(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Theme.surface, in: Circle())
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
    }

    /// 投稿の説明（点数の内わけ）
    private var caption: some View {
        HStack(spacing: 8) {
            Text("正解 \(game.correct) ・ パス \(game.turns.filter { $0.outcome == .pass }.count)" +
                 (game.cheats > 0 ? " ・ カンニング −\(game.cheats)" : ""))
                .font(.system(size: 15, weight: .semibold))
            if game.isNewBest {
                Text("自己ベスト")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(.white, in: Capsule())
            }
        }
        .padding(.horizontal, 6)
    }

    /// お題の一覧（BeReal のコメントの並び：太字の名前、灰色の本文）
    private var turns: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(game.turns) { t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(t.prompt).font(Theme.bold(15)).foregroundStyle(.white)
                    Text(detail(t)).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    if let effect = t.effect {
                        Text(effect.label).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            Rectangle().fill(Color(white: 0.16)).frame(height: 1).padding(.top, 4)
        }
        .padding(.horizontal, 6)
    }

    private func detail(_ t: Game.Turn) -> String {
        let outcome = switch t.outcome {
        case .correct: "正解"
        case .pass: "パス"
        case nil: "時間切れ"
        }
        guard let end = t.end else { return outcome }
        return outcome + String(format: " ・ %.1f秒", end - t.start)
    }

    /// もう一回（BeReal の白い「遅れて BeReal を投稿する」）
    private var again: some View {
        Button {
            player?.pause()
            game.startRound()
        } label: {
            Label("役を交代してもう一回", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(PillButtonStyle(height: 56))
        .accessibilityLabel("役を交代してもう一回")
        .padding(.horizontal, 16)
        .padding(.top, 30)
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
                VStack(spacing: 14) {
                    Wordmark(size: 40)
                    Text("お題はここに出ます").font(Theme.bold(22))
                    Text("声は出さずに、体だけで演じてください。").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(24)
            case .countdown(let n):
                VStack {
                    Wordmark()
                    Spacer()
                    Text("\(n)")
                        .font(.system(size: 240, weight: .heavy)).monospacedDigit()
                        .id(n)
                        .transition(.asymmetric(insertion: .scale(scale: 1.3).combined(with: .opacity), removal: .opacity))
                    Spacer()
                    Text("画面の前に立って").font(Theme.heavy(20)).foregroundStyle(Theme.secondary)
                }
                .padding(24)
            case .playing:
                playing
            case .results:
                VStack(spacing: 8) {
                    Wordmark()
                    Spacer()
                    Text("おつかれさま").font(Theme.bold(22)).foregroundStyle(Theme.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(game.score)").font(Theme.heavy(140))
                        Text("点").font(Theme.heavy(40))
                    }
                    Text("次は役を交代しよう").font(Theme.bold(18)).foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(24)
            }
        }
        .foregroundStyle(.white)
        .animation(.smooth(duration: 0.3), value: game.phase)
        .persistentSystemOverlays(.hidden)
    }

    private var playing: some View {
        VStack(spacing: 6) {
            Wordmark()
            TimerText(remaining: game.remaining, size: 20)
            Spacer()
            if let turn = game.current {
                Text(turn.prompt)
                    .font(.system(size: 104, weight: .heavy))
                    .tracking(-2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3)
                    .lineLimit(2)
                    .id(turn.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            Spacer()
            HStack {
                Chip(symbol: "speaker.slash.fill", text: "声は出さない")
                Spacer()
                Chip(symbol: "checkmark", text: "\(game.score)")
            }
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
                        (correct ? Color.white : Color.black).opacity(correct ? 1 : 0.8)
                        Text(correct ? "正解！" : "パス")
                            .font(.system(size: 110, weight: .heavy))
                            .foregroundStyle(correct ? .black : .white)
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
