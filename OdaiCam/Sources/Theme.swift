import SwiftUI

/// 見た目の決まり。BeReal. に合わせる：
/// 真っ黒な地、白い太字のロゴ（末尾にピリオド）、角の丸いファインダーと左上の内カメの小窓、
/// 白い輪のシャッター、灰色の丸い札、選んだものだけ白いカード。
/// 差し色は棒人間の黄色ひとつだけ。正解の瞬間・残り 10 秒・種明かしの帯にだけ使う
enum Theme {
    /// 棒人間の線と同じ黄色
    static let accent = Color(red: 1, green: 0.87, blue: 0.43)
    static let background = Color.black
    /// 行・カード（BeReal の設定やシートの濃い灰色）
    static let surface = Color(white: 0.11)
    /// 写真の上に乗せる札（「BTS Off」「私の友達のみ」）
    static let chip = Color(white: 0.18).opacity(0.82)
    static let secondary = Color(white: 0.56)
    static let tertiary = Color(white: 0.34)
    /// カンニング（BeReal の「⚠️」の赤）
    static let warning = Color(red: 1, green: 0.27, blue: 0.23)

    static let viewfinderRadius: CGFloat = 20
    static let wipeRadius: CGFloat = 14
    static let cardRadius: CGFloat = 18

    /// ロゴと見出しの太字（BeReal の詰まった太いゴシック）
    static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    static func bold(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    /// ロゴと数字の書体（BeReal. のロゴに近い Inter の極太。英数字だけ入れてある）
    static func brand(_ size: CGFloat) -> Font { .custom("OdaiCamInter-ExtraBold", fixedSize: size) }
    /// 残り時間の数字
    static func timer(_ size: CGFloat) -> Font { brand(size).monospacedDigit() }
}

/// ロゴ「OdaiCam.」（BeReal. と同じく、白い太字に句点）
struct Wordmark: View {
    var size: CGFloat = 22

    var body: some View {
        Text("OdaiCam.")
            .font(Theme.brand(size))
            .tracking(-size * 0.03)
            .foregroundStyle(.white)
            .accessibilityLabel("お題カメラ")
    }
}

/// アプリの印（アイコンと同じ。黒地にロゴだけ）
struct AppMark: View {
    var size: CGFloat = 60

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(.black)
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color(white: 0.2), lineWidth: 1))
            .overlay(Wordmark(size: size * 0.2))
            .frame(width: size, height: size)
    }
}

/// 山札ごとの記号（BeReal はすべて白い線画の記号）
extension Deck {
    var symbol: String {
        switch id {
        case "animal", "en-animal": "pawprint.fill"
        case "job", "en-job": "briefcase.fill"
        case "sport", "en-sport": "figure.run"
        case "action", "en-action": "hand.wave.fill"
        case "nomikai": "wineglass.fill"
        case "en-party": "party.popper.fill"
        case "couple", "en-couple": "heart.fill"
        case "aruaru", "en-relatable": "bubble.left.fill"
        case "muri", "en-impossible": "flame.fill"
        case "winter", "en-holiday": "snowflake"
        default: "pencil"
        }
    }

    /// プロフィールの丸い写真の代わりに使う 1 文字
    var initial: String { String(title.prefix(1)) }
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
        case .stick: String(localized: "骨組みの線だけが見える")
        case .silhouette: String(localized: "真っ黒な影だけが見える")
        case .mosaic: String(localized: "粗いモザイクが少しずつ晴れる")
        case .delay: String(localized: "3 秒前の動きが見える")
        case .peephole: String(localized: "小さな丸い窓だけがうろつく")
        }
    }
}

/// 端末の言葉とは別に、決めた言葉で訳を引く（種明かし動画は山札の言葉で書く）。
/// 訳は Localizable.strings と同じ表を使う。日本語は鍵そのもの
enum Words {
    static func text(_ key: String, language: String) -> String {
        guard language != "ja",
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// 写真の上に乗る灰色の札（BeReal の「BTS Off」「私の友達のみ」「オフ」）
struct Chip: View {
    let symbol: String?
    let text: String
    var active = true

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            }
            Text(text).font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(active ? .white : Theme.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.chip, in: Capsule())
    }
}

/// 札の形のボタン
struct ChipButton: View {
    let symbol: String?
    let text: String
    var active = true
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Chip(symbol: symbol, text: text, active: active) }
            .buttonStyle(PressStyle())
            .accessibilityLabel(label)
    }
}

/// プロフィールの丸（BeReal の右上の丸い写真）。写真の代わりに 1 文字
struct Avatar: View {
    let text: String
    var size: CGFloat = 32

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(white: 0.24), in: Circle())
    }
}

/// 白い丸いボタン（BeReal の「BeReal を投稿」）と、濃い灰色の丸いボタン
struct PillButtonStyle: ButtonStyle {
    var primary = true
    var height: CGFloat = 54
    var fontSize: CGFloat = 17
    /// 白の代わりに使う地の色（正解のボタンは棒人間の黄色）
    var fill: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .heavy))
            .foregroundStyle(primary ? .black : .white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(primary ? fill : Theme.surface, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 押すと少し縮む
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// BeReal のシャッター（白い太い輪）。何が始まるか分かるよう、中に「スタート」と書く
struct ShutterButton: View {
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 6)
                Circle().fill(.white).padding(11)
                Text("スタート")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.black)
            }
            .frame(width: 92, height: 92)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel("あそぶ")
    }
}

/// 上の列の白い記号だけのボタン（BeReal の「∨」「👥」「📅」）
struct BarButton: View {
    let symbol: String
    /// 読み上げの名前（訳の鍵。UI テストもこの日本語で探す）
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

/// 上の列：左のボタン・中央のロゴ・右のボタン
struct TopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ZStack {
            Wordmark()
            HStack {
                leading
                Spacer()
                trailing
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
    }
}

/// 残り時間（BeReal の撮影画面の「01:05」）
struct TimerText: View {
    let remaining: Double
    var size: CGFloat = 17

    var body: some View {
        let seconds = Int(remaining.rounded(.up))
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(Theme.timer(size))
            .foregroundStyle(remaining <= 10 ? Theme.accent : .white)
            .contentTransition(.numericText(countsDown: true))
            .animation(.default, value: seconds)
    }
}

/// 上から降りてくる知らせ（BeReal の「⚠️ BeReal の時間です ⚠️」の通知と同じ形）
struct NoticeBanner: View {
    let title: String
    let message: String
    var trailing: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 12) {
            AppMark(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(tint)
                Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(Theme.heavy(26)).foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(white: 0.13).opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }
}
