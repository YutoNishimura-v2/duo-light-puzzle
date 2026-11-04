import AudioToolbox
import SwiftUI

/// 配色・文字・部品。画面はここの部品だけで組む
enum Theme {
    // 夜のパーティーの色。深い藍の地（カメラの映像が映える）に、ピンクの差し色
    static let bg = Color(hex: 0x1B1035)
    static let surface = Color(hex: 0x2A1D52)
    static let surfaceHigh = Color(hex: 0x3A2A6B)
    static let coral = Color(hex: 0xFF4F7B)
    static let purple = Color(hex: 0x7B2FF7)
    static let sunset = Color(hex: 0xFFB020)
    static let mint = Color(hex: 0x2EE59D)
    static let sky = Color(hex: 0x0A84FF)
    static let violet = Color(hex: 0xBF5AF2)
    static let warning = Color(hex: 0xFF3B30)
    static let ink = Color(hex: 0x1B1035)
    static let textSecondary = Color(hex: 0xB9B0D9)

    static let brand = LinearGradient(colors: [coral, purple], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .semibold, design: .rounded) }

    static let radius: CGFloat = 24
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// 山札ごとの色と絵文字
extension Deck {
    var color: Color {
        switch id {
        case "animal": Color(hex: 0x34C759)
        case "job": Color(hex: 0x0A84FF)
        case "sport": Color(hex: 0xFF9F0A)
        case "action": Color(hex: 0xBF5AF2)
        default: Color(hex: 0xFF375F)
        }
    }

    var emoji: String {
        switch id {
        case "animal": "🐾"
        case "job": "👷"
        case "sport": "⚽️"
        case "action": "🏃"
        default: "✍️"
        }
    }
}

extension Effect {
    var symbol: String {
        switch self {
        case .stick: "figure.walk"
        case .silhouette: "person.fill"
        case .mosaic: "square.grid.3x3.fill"
        case .delay: "clock.arrow.circlepath"
        case .peephole: "circle.dashed"
        }
    }

    var hint: String {
        switch self {
        case .stick: "骨組みの線だけ"
        case .silhouette: "真っ黒な影だけ"
        case .mosaic: "だんだん晴れるモザイク"
        case .delay: "3 秒前の動き"
        case .peephole: "うろつく小さな窓"
        }
    }
}

// MARK: 部品

/// いちばん大事な操作。下に濃い色の「厚み」があり、押すと沈む（Duolingo 型の立体ボタン）
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.coral
    var height: CGFloat = 64

    func makeBody(configuration: Configuration) -> some View {
        let depth: CGFloat = 6
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.title(22))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .offset(y: pressed ? depth : 0)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(color.mix(with: .black, by: 0.3))
                    .offset(y: depth)
            )
            .padding(.bottom, depth)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
    }
}

/// 二番目の操作
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.title(18))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 押すと少し縮むだけのボタン（カードなど）
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// すりガラスのカプセル（プレイ中の上の表示）
struct GlassCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

/// 残り時間の輪
struct TimerRing: View {
    let remaining: Double
    let total: Double
    var size: CGFloat = 64

    var body: some View {
        let fraction = total > 0 ? remaining / total : 0
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 7)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(remaining <= 10 ? Theme.warning : Theme.mint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: fraction)
            Text("\(Int(remaining.rounded(.up)))")
                .font(Theme.title(size * 0.36)).monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: size, height: size)
    }
}

/// 正解のときの紙吹雪（軽い Canvas の粒）
struct Confetti: View {
    let start: Date
    private static let colors: [Color] = [Theme.coral, Theme.sunset, Theme.mint, Theme.sky, Theme.violet, .white]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard t < 1.6 else { return }
                for i in 0..<70 {
                    // 粒ごとに決まった乱数（毎フレーム同じ動きにする）
                    let seed = Double(i) * 12.9898
                    let r1 = abs(sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let r2 = abs(sin(seed * 1.7) * 23421.631).truncatingRemainder(dividingBy: 1)
                    let r3 = abs(sin(seed * 2.3) * 9371.113).truncatingRemainder(dividingBy: 1)
                    let angle = -Double.pi / 2 + (r1 - 0.5) * 2.2
                    let speed = 500 + r2 * 600
                    let x = size.width / 2 + cos(angle) * speed * t
                    let y = size.height * 0.62 + sin(angle) * speed * t + 900 * t * t
                    let rect = CGRect(x: x, y: y, width: 9, height: 14)
                    var piece = ctx
                    piece.opacity = max(0, 1 - t / 1.6)
                    piece.translateBy(x: rect.midX, y: rect.midY)
                    piece.rotate(by: .radians(t * (4 + r3 * 8)))
                    piece.fill(Path(roundedRect: CGRect(x: -4.5, y: -7, width: 9, height: 14), cornerRadius: 2),
                               with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 効果音（端末に入っている音だけを使う）
enum Sound {
    static func tick() { AudioServicesPlaySystemSound(1104) }
    static func correct() { AudioServicesPlaySystemSound(1407) }
    static func pass() { AudioServicesPlaySystemSound(1105) }
    static func buzzer() { AudioServicesPlaySystemSound(1073) }
    static func finish() { AudioServicesPlaySystemSound(1025) }
}
