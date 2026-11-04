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
                .tint(Theme.coral)
        }
    }
}

/// 内側の画面：当てる人。カメラ越しに演技を見て当てる。お題は見えない
struct GuesserView: View {
    @AppStorage("onboarded") private var onboarded = false
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
    @State private var editingDeck = false
    @State private var started = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if onboarded {
                // プレビューは常に下に置く（外側の画面の表示は撮影画面があることが前提）
                CameraPreview(camera: camera, ready: cameraReady).ignoresSafeArea()
                switch game.phase {
                case .menu:
                    HomeView(game: game, cameraReady: cameraReady, cameraDenied: cameraDenied,
                             showSettings: $showSettings, editingDeck: $editingDeck)
                case .countdown(let n):
                    CountdownView(n: n, effect: game.effectsOn ? (game.fixedEffect?.label ?? "おまかせ") : nil)
                case .playing:
                    PlayView(game: game, seenFrame: seenFrame, voiceOn: game.voiceJudge && voiceReady)
                case .results:
                    ResultsView(game: game)
                }
            } else {
                OnboardingView {
                    withAnimation(.spring) { onboarded = true }
                    Task { await startCamera() }
                }
            }
        }
        // 撮影画面が内側に全画面で出ていて、撮影が動いている間だけ、システムが外側の画面に出す
        .sceneAccessory {
            CameraCaptureAccessory {
                ActorView(game: game)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(game: game, voiceReady: voiceReady, innerReady: innerReady, editingDeck: $editingDeck) {
                showSettings = false
                onboarded = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $editingDeck) { DeckEditor(game: game) }
        .task { if onboarded { await startCamera() } }
        .onDisappear { camera.stop() }
    }

    private func startCamera() async {
        guard !started else { return }
        started = true
        game.startRecording = { [camera] in camera.startRecording(rotationAngle: CameraPreview.PreviewView.latestCaptureAngle) }
        game.stopRecording = { [camera] in camera.stopRecording() }
        camera.onReady = { inner in
            cameraReady = true
            innerReady = inner
            if !inner { game.cheatGuard = false }
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

// MARK: - 初回の説明と、許可の前置き

struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0

    private let pages: [(emoji: String, title: String, text: String)] = [
        ("🙌", "お題は外側の画面に", "Duo を開いて持つ人が「当てる人」。外側の画面の前に立つ人だけがお題を見て、声を出さずに演じます。"),
        ("🕶️", "でも、見えるのは画面だけ", "当てる人はカメラ越しにしか見られません。しかも棒人間や影絵に変わります。顔を上げて直接見たらカンニング！"),
        ("🎤", "答えは声に出すだけ", "当たると自動で次のお題へ。終わったら「見えていた画面 → 本当の演技」の種明かし動画ができます。"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 20) {
                        Text(pages[i].emoji).font(.system(size: 110))
                            .frame(width: 200, height: 200)
                            .background(Theme.brand.opacity(0.35), in: Circle())
                        Text(pages[i].title).font(Theme.display(32)).multilineTextAlignment(.center)
                        Text(pages[i].text).font(Theme.body(17)).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    .tag(i)
                }
                // 許可の前置き（なぜ要るかを先に伝えてから、OS の確認を出す）
                VStack(spacing: 18) {
                    Text("📷🎙️").font(.system(size: 80))
                    Text("あそぶ前に").font(Theme.display(32))
                    VStack(alignment: .leading, spacing: 14) {
                        primer("camera.fill", "カメラ", "演技を写して、しばりをかける・種明かし動画を作る")
                        primer("mic.fill", "マイクと音声認識", "答えを聞き取って自動で判定する（端末の中だけで処理）")
                        primer("photo.on.rectangle", "写真", "種明かし動画を保存するときだけ")
                    }
                    .padding(20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .padding(.horizontal, 24)
                }
                .tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button(page < pages.count ? "つぎへ" : "許可してはじめる") {
                if page < pages.count {
                    withAnimation(.spring) { page += 1 }
                } else {
                    finish()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func primer(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.coral).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.title(17))
                Text(text).font(Theme.body(14)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - ホーム

struct HomeView: View {
    @Bindable var game: Game
    let cameraReady: Bool
    let cameraDenied: Bool
    @Binding var showSettings: Bool
    @Binding var editingDeck: Bool

    private var decks: [Deck] { Deck.builtIn + (CustomDeck.deck.map { [$0] } ?? []) }

    var body: some View {
        ZStack {
            Theme.bg.opacity(0.94).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    roles
                    section("山札をえらぶ")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(decks) { deck in deckCard(deck) }
                        if CustomDeck.deck == nil { newDeckCard }
                    }
                    section("見え方しばり")
                    effectChips
                    section("時間")
                    timePills
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Button(cameraReady ? "あそぶ" : (cameraDenied ? "カメラが使えません" : "カメラを準備中…")) {
                        game.startRound()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!cameraReady)
                    .opacity(cameraReady ? 1 : 0.5)
                    if cameraDenied {
                        Text("設定アプリでカメラを許可してください").font(Theme.body(13)).foregroundStyle(Theme.warning)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .background(LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .center))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("お題カメラ").font(Theme.display(36))
                Text("Duo でしか遊べないジェスチャーゲーム").font(Theme.body(14)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("設定")
        }
    }

    private var roles: some View {
        HStack(spacing: 12) {
            role("📱", "持つ人", "画面越しに当てる")
            role("🙌", "外側の前", "声を出さずに演じる")
        }
    }

    private func role(_ emoji: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(emoji).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.title(15))
                Text(text).font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Theme.title(18)).padding(.top, 4)
    }

    private func deckCard(_ deck: Deck) -> some View {
        let selected = game.deck.id == deck.id
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { game.deck = deck }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(deck.emoji).font(.system(size: 40))
                Spacer(minLength: 0)
                Text(deck.title).font(Theme.title(20)).foregroundStyle(.white)
                Text("\(deck.prompts.count) 枚").font(Theme.body(13)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(
                LinearGradient(colors: [deck.color, deck.color.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white).padding(12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 3))
            .scaleEffect(selected ? 1 : 0.97)
        }
        .buttonStyle(PressableStyle())
    }

    private var newDeckCard: some View {
        Button { editingDeck = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "plus").font(.system(size: 30, weight: .bold))
                Spacer(minLength: 0)
                Text("お題帳をつくる").font(Theme.title(18))
                Text("内輪ネタで遊ぶ").font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6])).foregroundStyle(.white.opacity(0.3)))
        }
        .buttonStyle(PressableStyle())
    }

    private var effectChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip("おまかせ", "dice.fill", selected: game.effectsOn && game.fixedEffect == nil) {
                    game.effectsOn = true
                    game.fixedEffect = nil
                }
                ForEach(Effect.allCases) { e in
                    chip(e.label, e.symbol, selected: game.effectsOn && game.fixedEffect == e) {
                        game.effectsOn = true
                        game.fixedEffect = e
                    }
                }
                chip("しばりなし", "eye", selected: !game.effectsOn) { game.effectsOn = false }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { action() }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.title(15))
                .padding(.horizontal, 16).frame(height: 44)
                .foregroundStyle(selected ? Theme.ink : .white)
                .background(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.surface), in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private var timePills: some View {
        HStack(spacing: 0) {
            ForEach([30.0, 60.0, 90.0], id: \.self) { t in
                let selected = game.roundLength == t
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { game.roundLength = t }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text("\(Int(t)) 秒").font(Theme.title(17))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(selected ? Theme.ink : .white)
                        .background(selected ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface, in: Capsule())
    }
}

// MARK: - 設定

struct SettingsSheet: View {
    @Bindable var game: Game
    let voiceReady: Bool
    let innerReady: Bool
    @Binding var editingDeck: Bool
    let replayOnboarding: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $game.voiceJudge) {
                        Label { setting("声で自動判定", voiceReady ? "答えを声に出すと、合っていれば自動で正解" : "この端末では使えません") }
                            icon: { Image(systemName: "waveform") }
                    }
                    .disabled(!voiceReady)
                    Toggle(isOn: $game.cheatGuard) {
                        Label { setting("カンニング禁止", innerReady ? "顔を上げて本人を直接見たら −1" : "この端末では使えません（2 つのカメラを同時に使えない）") }
                            icon: { Image(systemName: "eye.trianglebadge.exclamationmark") }
                    }
                    .disabled(!innerReady)
                }
                Section {
                    Button("お題帳を編集", systemImage: "square.and.pencil") { editingDeck = true }
                    Button("遊び方をもう一度見る", systemImage: "questionmark.circle", action: replayOnboarding)
                }
                Section("記録") {
                    LabeledContent("自己ベスト", value: "\(game.best) 点")
                }
                Section("診断") {
                    Text(MultiCamProbe.summary).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func setting(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DeckEditor: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss
    @State private var text = CustomDeck.text

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("1 行に 1 つ。友だちの名前、職場のネタ、思い出の場面など。").font(Theme.body(14)).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
            .background(Theme.bg)
            .navigationTitle("お題帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        CustomDeck.text = text
                        if let deck = CustomDeck.deck { game.deck = deck }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - カウントダウン

struct CountdownView: View {
    let n: Int
    let effect: String?

    var body: some View {
        ZStack {
            Theme.brand.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("演じる人は外側の画面へ！").font(Theme.title(20))
                Text("\(n)")
                    .font(Theme.display(180)).monospacedDigit()
                    .id(n)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
                if let effect {
                    Label("しばり：\(effect)", systemImage: "eye.slash.fill")
                        .font(Theme.title(17))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.25), in: Capsule())
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: n)
        }
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
                    Image(decorative: seenFrame, scale: 1).resizable().scaledToFit().ignoresSafeArea()
                }
            }
            VStack(spacing: 12) {
                hud
                Spacer()
                if voiceOn {
                    Label(game.heard.isEmpty ? "答えを声に出して！" : game.heard, systemImage: "mic.fill")
                        .font(Theme.title(18)).lineLimit(1)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .animation(.easeOut(duration: 0.15), value: game.heard)
                }
                HStack(spacing: 12) {
                    Button { game.answer(.pass) } label: { Label("パス", systemImage: "forward.fill") }
                        .buttonStyle(PrimaryButtonStyle(color: Color(hex: 0xE08E00), height: 72))
                    Button { game.answer(.correct) } label: { Label("正解", systemImage: "checkmark") }
                        .buttonStyle(PrimaryButtonStyle(color: Color(hex: 0x16B87A), height: 72))
                }
            }
            .padding(16)
            flash
            cheatBanner
        }
    }

    private var hud: some View {
        HStack(alignment: .center) {
            GlassCapsule {
                Label("\(game.score)", systemImage: "checkmark.circle.fill")
                    .font(Theme.title(24)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring, value: game.score)
            }
            Spacer()
            if let effect = game.current?.effect {
                GlassCapsule {
                    Label(effect.label, systemImage: effect.symbol).font(Theme.title(16))
                }
                .id(effect)
                .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            TimerRing(remaining: game.remaining, total: game.roundLength)
                .padding(4)
                .background(.ultraThinMaterial, in: Circle())
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: game.current?.effect)
    }

    /// 正解・パスのとき画面全体を一瞬光らせる
    private var flash: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            if let at = game.lastAnswerAt, let last = game.lastAnswer {
                let t = context.date.timeIntervalSince(at)
                if t < 0.7 {
                    let correct = last.outcome == .correct
                    ZStack {
                        (correct ? Theme.mint : Theme.sunset).opacity(0.85 * (1 - t / 0.7)).ignoresSafeArea()
                        VStack(spacing: 6) {
                            Text(correct ? "正解！" : "パス").font(Theme.display(64))
                            Text(last.prompt).font(Theme.title(26))
                        }
                        .foregroundStyle(.white)
                        .scaleEffect(1 + 0.15 * (1 - min(t / 0.2, 1)))
                        .opacity(1 - max(0, (t - 0.45) / 0.25))
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var cheatBanner: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            if let cheat = game.lastCheat, context.date.timeIntervalSince(cheat) < 1.5 {
                VStack {
                    Label("カンニング！ −1", systemImage: "eye.trianglebadge.exclamationmark.fill")
                        .font(Theme.display(34)).foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Theme.warning, in: Capsule())
                        .shadow(color: Theme.warning.opacity(0.5), radius: 20)
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 結果

struct ResultsView: View {
    let game: Game
    @State private var shown = 0
    @State private var player: AVPlayer?
    @State private var message: String?
    @State private var confettiAt: Date?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    scoreHero
                    highlightCard
                    turnList
                }
                .padding(20)
                .padding(.bottom, 150)
            }
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Button("役を交代してもう一回") {
                        player?.pause()
                        game.startRound()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("ホームへ") {
                        player?.pause()
                        game.backToMenu()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                .background(LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .center))
            }
            if let confettiAt { Confetti(start: confettiAt).ignoresSafeArea() }
        }
        .task {
            if let url = game.highlightURL, player == nil {
                player = AVPlayer(url: url)
                player?.play()
            }
            // 点数を数え上げる
            shown = 0
            for i in 0...max(game.score, 0) {
                withAnimation(.spring(response: 0.2)) { shown = i }
                try? await Task.sleep(for: .milliseconds(max(40, 700 / max(game.score, 1))))
            }
            if game.isNewBest { confettiAt = Date() }
        }
        .onChange(of: game.highlightURL) { _, url in
            if let url {
                player = AVPlayer(url: url)
                player?.play()
            }
        }
    }

    private var scoreHero: some View {
        VStack(spacing: 6) {
            if game.isNewBest {
                Label("自己ベスト！", systemImage: "crown.fill")
                    .font(Theme.title(16)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.sunset, in: Capsule())
            }
            Text("\(shown)")
                .font(Theme.display(110)).monospacedDigit()
                .contentTransition(.numericText())
            Text("点").font(Theme.title(20)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                stat("正解", game.correct, Theme.mint)
                stat("パス", game.turns.filter { $0.outcome == .pass }.count, Theme.sunset)
                if game.cheats > 0 { stat("カンニング", -game.cheats, Theme.warning) }
            }
        }
        .padding(.top, 20)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(Theme.title(22)).monospacedDigit().foregroundStyle(color)
            Text(title).font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var highlightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("種明かし動画", systemImage: "film.stack.fill").font(Theme.title(18))
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else if let error = game.highlightError {
                    Text(error).font(Theme.body(14)).foregroundStyle(Theme.warning).padding()
                } else {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("名場面をつないでいます…").font(Theme.body(14)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let url = game.highlightURL {
                HStack(spacing: 10) {
                    ShareLink(item: url) {
                        Label("共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        Task { message = await Camera.saveVideo(url) }
                    } label: {
                        Label(message ?? "保存", systemImage: message == "保存しました" ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var turnList: some View {
        VStack(spacing: 0) {
            ForEach(game.turns) { t in
                HStack(spacing: 12) {
                    Image(systemName: t.outcome == .correct ? "checkmark.circle.fill" : "forward.circle.fill")
                        .font(.title3).foregroundStyle(t.outcome == .correct ? Theme.mint : Theme.sunset)
                    Text(t.prompt).font(Theme.title(17))
                    Spacer()
                    if let effect = t.effect {
                        Label(effect.label, systemImage: effect.symbol).font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 12).padding(.horizontal, 16)
                if t.id != game.turns.last?.id { Divider().overlay(.white.opacity(0.08)) }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: - 外側の画面（演じる人）

struct ActorView: View {
    let game: Game

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch game.phase {
            case .menu:
                VStack(spacing: 14) {
                    Text("🙌").font(.system(size: 90))
                    Text("演じる人はこちら").font(Theme.display(34))
                    Text("お題がここに出ます。声は出さずに体だけで！").font(Theme.body(17)).foregroundStyle(Theme.textSecondary)
                }
                .multilineTextAlignment(.center).padding(24)
            case .countdown(let n):
                ZStack {
                    Theme.brand.ignoresSafeArea()
                    Text("\(n)").font(Theme.display(200)).monospacedDigit()
                        .id(n).transition(.scale(scale: 1.6).combined(with: .opacity))
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: n)
            case .playing:
                playing
            case .results:
                VStack(spacing: 12) {
                    Text("🎉").font(.system(size: 90))
                    Text("おつかれさま！").font(Theme.display(36))
                    Text("\(game.score) 点").font(Theme.title(28))
                    Text("次は役を交代しよう").font(Theme.body(17)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    private var playing: some View {
        VStack(spacing: 14) {
            // 残り時間の細い帯
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(game.remaining <= 10 ? Theme.warning : Theme.mint)
                            .frame(width: geo.size.width * max(0, game.remaining / max(game.roundLength, 1)))
                    }
            }
            .frame(height: 10)
            if let turn = game.current {
                Text(turn.prompt)
                    .font(Theme.display(88))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3)
                    .lineLimit(2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                    .background(
                        LinearGradient(colors: [game.deck.color, game.deck.color.mix(with: .black, by: 0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .id(turn.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            HStack {
                Label("声は出さずに！", systemImage: "speaker.slash.fill")
                Spacer()
                Label("\(game.score)", systemImage: "checkmark.circle.fill").monospacedDigit()
            }
            .font(Theme.title(20))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: game.current?.id)
        .overlay {
            // 当たったら演じる人にも知らせる
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                if let at = game.lastAnswerAt, let last = game.lastAnswer, context.date.timeIntervalSince(at) < 0.7 {
                    let t = context.date.timeIntervalSince(at)
                    ZStack {
                        (last.outcome == .correct ? Theme.mint : Theme.sunset).opacity(0.9 * (1 - t / 0.7)).ignoresSafeArea()
                        Text(last.outcome == .correct ? "正解！" : "パス").font(Theme.display(90)).foregroundStyle(.white)
                            .opacity(1 - max(0, (t - 0.45) / 0.25))
                    }
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
