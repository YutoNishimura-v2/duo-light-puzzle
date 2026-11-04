import Observation
import SwiftUI

/// 外側の画面に出す光の形。瞳に映る形（キャッチライト）になる
enum LightShape: String, CaseIterable, Identifiable {
    case full, ring, window, strip, twinStrips, star, heart

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: "全面"
        case .ring: "リング"
        case .window: "窓"
        case .strip: "帯"
        case .twinStrips: "2本の帯"
        case .star: "星"
        case .heart: "ハート"
        }
    }

    var symbol: String {
        switch self {
        case .full: "rectangle.fill"
        case .ring: "circle"
        case .window: "square.grid.2x2"
        case .strip: "rectangle.portrait"
        case .twinStrips: "pause"
        case .star: "star.fill"
        case .heart: "heart.fill"
        }
    }
}

/// 撮影画面（内側）と光（外側）が同じものを読む
@MainActor
@Observable
final class LightModel {
    var shape = LightShape.ring
    /// 色温度（ケルビン）。2700 で電球色、6500 で昼光色
    var kelvin = 5000.0
    /// 0 で色温度どおり、1 で hue の色をそのまま
    var tint = 0.0
    var hue = 0.9
    /// 光の明るさ（0〜1）。画面自体の明るさは最大にする
    var level = 1.0
    var isOn = true
    /// 被写体が外側を触ってシャッターを切れるようにする
    var subjectShutter = true
    /// 外側の画面に出ているか（アクセサリの画面が出ている間 true）
    var accessoryVisible = false

    var color: Color {
        let white = Self.rgb(kelvin: kelvin)
        let tinted = Self.rgb(hue: hue)
        let mix = { (a: Double, b: Double) in a + (b - a) * self.tint }
        return Color(red: mix(white.0, tinted.0), green: mix(white.1, tinted.1), blue: mix(white.2, tinted.2))
            .opacity(isOn ? level : 0)
    }

    /// 色温度を近似の RGB にする（Tanner Helland の近似式）
    static func rgb(kelvin: Double) -> (Double, Double, Double) {
        let t = kelvin / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        let c = { (v: Double) in min(max(v, 0), 255) / 255 }
        return (c(r), c(g), c(b))
    }

    static func rgb(hue: Double) -> (Double, Double, Double) {
        let ui = UIColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r, g, b)
    }
}

/// 光そのもの。外側の画面いっぱいに描く（内側のプレビューにも小さく使う）
struct LightView: View {
    let model: LightModel

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black
                shapeView(size: size).foregroundStyle(model.color)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func shapeView(size: CGSize) -> some View {
        let m = min(size.width, size.height)
        switch model.shape {
        case .full:
            Rectangle()
        case .ring:
            Circle().strokeBorder(lineWidth: m * 0.14).frame(width: m * 0.9, height: m * 0.9)
        case .window:
            // 4枚のガラスの窓。昔の肖像画で好まれた形
            Grid(horizontalSpacing: m * 0.05, verticalSpacing: m * 0.05) {
                GridRow { Rectangle(); Rectangle() }
                GridRow { Rectangle(); Rectangle() }
            }
            .frame(width: size.width * 0.8, height: size.height * 0.8)
        case .strip:
            Rectangle().frame(width: size.width * 0.32, height: size.height * 0.9)
        case .twinStrips:
            HStack(spacing: size.width * 0.3) {
                Rectangle(); Rectangle()
            }
            .frame(width: size.width * 0.75, height: size.height * 0.9)
        case .star:
            Image(systemName: "star.fill").resizable().scaledToFit().frame(width: m * 0.9)
        case .heart:
            Image(systemName: "heart.fill").resizable().scaledToFit().frame(width: m * 0.9)
        }
    }
}
