import AudioToolbox
import SwiftUI

/// 見た目の決まり。iPhone の「カメラ」アプリに合わせる：
/// 黒い地に映像、操作はすりガラス（Liquid Glass）、選んだものだけ黄色、文字は SF Pro、絵は SF Symbols
enum Theme {
    /// カメラアプリの選択色
    static let accent = Color(.systemYellow)
    static let correct = Color(.systemGreen)
    static let pass = Color(.systemOrange)
    static let warning = Color(.systemRed)
    /// カード（ヘルスケア・フィットネスの集計カードと同じ）
    static let card = Color(.secondarySystemBackground)
    static let cardRadius: CGFloat = 22

    /// 大きな数字（フィットネスと同じ丸い数字）
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// 山札ごとの色と記号（設定アプリの項目と同じ、色つきの角丸に白い記号）
extension Deck {
    var color: Color {
        switch id {
        case "animal": Color(.systemGreen)
        case "job": Color(.systemBlue)
        case "sport": Color(.systemOrange)
        case "action": Color(.systemPurple)
        default: Color(.systemPink)
        }
    }

    var symbol: String {
        switch id {
        case "animal": "pawprint.fill"
        case "job": "briefcase.fill"
        case "sport": "figure.run"
        case "action": "hand.wave.fill"
        default: "pencil"
        }
    }
}

extension Effect {
    var symbol: String {
        switch self {
        case .stick: "figure.stand"
        case .silhouette: "person.fill"
        case .mosaic: "square.grid.3x3.fill"
        case .delay: "clock.arrow.circlepath"
        case .peephole: "circle.dashed"
        }
    }

    var hint: String {
        switch self {
        case .stick: "骨組みの線だけが見える"
        case .silhouette: "真っ黒な影だけが見える"
        case .mosaic: "粗いモザイクが少しずつ晴れる"
        case .delay: "3 秒前の動きが見える"
        case .peephole: "小さな丸い窓だけがうろつく"
        }
    }
}

/// 設定アプリと同じ、色つきの角丸に白い記号
struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

/// すりガラスの丸いボタン（カメラアプリの上の列と同じ）
struct GlassIconButton: View {
    let symbol: String
    var active = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .white)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

/// 残り時間（カメラアプリの録画時間の表示と同じ。最後の 10 秒は赤）
struct RecordingTimer: View {
    let remaining: Double

    var body: some View {
        let seconds = Int(remaining.rounded(.up))
        let urgent = remaining <= 10
        HStack(spacing: 6) {
            Circle().fill(urgent ? .white : Theme.warning).frame(width: 7, height: 7)
            Text(String(format: "00:%02d", min(seconds, 99)))
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(urgent ? Theme.warning : Color.black.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .animation(.default, value: seconds)
    }
}

/// カメラアプリのシャッターボタン
struct ShutterButton: View {
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: 2)
            }
        }
        .buttonStyle(ShutterStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel("あそぶ")
    }

    private struct ShutterStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
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
