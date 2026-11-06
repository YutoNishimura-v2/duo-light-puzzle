import CoreGraphics
import Foundation

/// 「背景を変える」しばりの景色。画像は持たず、コードで描く（宇宙・海・教室・ステージ）。
/// 座標は CGContext のまま左下が原点。大きさはしばりの処理の大きさ（縦長）に合わせる。
/// 星や泡の並びは決まった種から作るので、毎回同じ絵になる（CI の画面写真がぶれない）
enum Backdrop {
    static func image(_ effect: Effect, size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        switch effect {
        case .space: space(ctx, rect)
        case .sea: sea(ctx, rect)
        case .classroom: classroom(ctx, rect)
        case .stage: stage(ctx, rect)
        default:
            ctx.setFillColor(rgb(0, 0, 0))
            ctx.fill(rect)
        }
        return ctx.makeImage()
    }

    // MARK: 宇宙：濃い紺から紫へ、星雲のもや、星、下に大きな惑星、右上に輪のある星

    private static func space(_ ctx: CGContext, _ r: CGRect) {
        let w = r.width, h = r.height, u = min(w, h) / 540
        vertical(ctx, r, top: rgb(0.02, 0.02, 0.08), bottom: rgb(0.10, 0.04, 0.20))
        // 星雲（大きくて薄い色のもや）
        glow(ctx, at: CGPoint(x: w * 0.25, y: h * 0.7), radius: w * 0.7, color: rgb(0.55, 0.15, 0.6, 0.35))
        glow(ctx, at: CGPoint(x: w * 0.85, y: h * 0.45), radius: w * 0.6, color: rgb(0.1, 0.45, 0.7, 0.3))
        glow(ctx, at: CGPoint(x: w * 0.5, y: h * 0.9), radius: w * 0.5, color: rgb(0.2, 0.2, 0.7, 0.25))
        // 星
        var rand = Seeded(7)
        let count = Int(w * h / 900)
        for _ in 0..<count {
            let p = CGPoint(x: rand.next() * w, y: rand.next() * h)
            let s = (0.6 + rand.next() * 1.6) * u
            ctx.setFillColor(rgb(1, 1, 1, 0.35 + rand.next() * 0.65))
            ctx.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
        }
        // 光る大きな星（十字の光）
        for _ in 0..<7 {
            let p = CGPoint(x: rand.next() * w, y: h * 0.3 + rand.next() * h * 0.7)
            let s = (8 + rand.next() * 10) * u
            glow(ctx, at: p, radius: s * 1.6, color: rgb(0.8, 0.9, 1, 0.6))
            ctx.setStrokeColor(rgb(1, 1, 1, 0.8))
            ctx.setLineWidth(1.2 * u)
            ctx.move(to: CGPoint(x: p.x - s, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + s, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - s)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + s))
            ctx.strokePath()
        }
        // 左の輪のある星（上の端やファインダーの上のチップに隠れないよう、枠の内側に置く）
        let ringed = CGPoint(x: w * 0.22, y: h * 0.62)
        let rr = 36 * u
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: ringed.x - rr, y: ringed.y - rr, width: rr * 2, height: rr * 2))
        ctx.clip()
        radial(ctx, from: CGPoint(x: ringed.x - rr * 0.4, y: ringed.y + rr * 0.4), to: ringed, radius: rr * 1.3,
               colors: [rgb(1, 0.85, 0.6), rgb(0.75, 0.45, 0.25), rgb(0.3, 0.12, 0.08)])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: ringed.x, y: ringed.y)
        ctx.rotate(by: -0.35)
        ctx.setStrokeColor(rgb(1, 0.9, 0.7, 0.75))
        ctx.setLineWidth(5 * u)
        ctx.strokeEllipse(in: CGRect(x: -rr * 1.9, y: -rr * 0.45, width: rr * 3.8, height: rr * 0.9))
        ctx.restoreGState()
        // 下の大きな惑星（地球のような青、ふちの大気が光る）
        let pr = w * 1.1
        let pc = CGPoint(x: w * 0.5, y: -pr + h * 0.17)
        glow(ctx, at: pc, radius: pr * 1.12, color: rgb(0.3, 0.6, 1, 0.55))
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2))
        ctx.clip()
        vertical(ctx, CGRect(x: 0, y: 0, width: w, height: h * 0.17),
                 top: rgb(0.35, 0.7, 1), bottom: rgb(0.05, 0.15, 0.4))
        // 雲の帯
        var clouds = Seeded(11)
        for _ in 0..<9 {
            let cx = clouds.next() * w, cy = clouds.next() * h * 0.14
            let cw = (60 + clouds.next() * 120) * u
            ctx.setFillColor(rgb(1, 1, 1, 0.25))
            ctx.fillEllipse(in: CGRect(x: cx - cw / 2, y: cy - 6 * u, width: cw, height: 12 * u))
        }
        ctx.restoreGState()
    }

    // MARK: 海：上は明るい水色、下は深い青。差し込む光、泡、砂の底、海藻

    private static func sea(_ ctx: CGContext, _ r: CGRect) {
        let w = r.width, h = r.height, u = min(w, h) / 540
        vertical(ctx, r, top: rgb(0.25, 0.8, 0.9), bottom: rgb(0.02, 0.18, 0.4))
        // 水面のゆらぎ
        glow(ctx, at: CGPoint(x: w * 0.5, y: h * 1.05), radius: w * 0.9, color: rgb(0.8, 1, 1, 0.45))
        // 上から差し込む光の筋
        var rand = Seeded(23)
        for i in 0..<6 {
            let x = w * (CGFloat(i) + 0.3 + rand.next() * 0.4) / 6
            let top = 18 * u + rand.next() * 26 * u
            let lean = (rand.next() - 0.5) * w * 0.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - top, y: h))
            path.addLine(to: CGPoint(x: x + top, y: h))
            path.addLine(to: CGPoint(x: x + lean + top * 3, y: h * 0.2))
            path.addLine(to: CGPoint(x: x + lean - top * 2, y: h * 0.2))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            linear(ctx, from: CGPoint(x: x, y: h), to: CGPoint(x: x, y: h * 0.2),
                   colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)])
            ctx.restoreGState()
        }
        // 砂の底（ゆるい波の形）
        let sand = CGMutablePath()
        sand.move(to: .zero)
        sand.addLine(to: CGPoint(x: 0, y: h * 0.15))
        sand.addCurve(to: CGPoint(x: w * 0.55, y: h * 0.12),
                      control1: CGPoint(x: w * 0.2, y: h * 0.19), control2: CGPoint(x: w * 0.35, y: h * 0.1))
        sand.addCurve(to: CGPoint(x: w, y: h * 0.17),
                      control1: CGPoint(x: w * 0.75, y: h * 0.14), control2: CGPoint(x: w * 0.9, y: h * 0.2))
        sand.addLine(to: CGPoint(x: w, y: 0))
        sand.closeSubpath()
        ctx.saveGState()
        ctx.addPath(sand)
        ctx.clip()
        vertical(ctx, CGRect(x: 0, y: 0, width: w, height: h * 0.2), top: rgb(0.85, 0.75, 0.5), bottom: rgb(0.5, 0.4, 0.25))
        ctx.restoreGState()
        // 海藻（左右の端に、ゆらいだ太い線）
        for (i, base) in [w * 0.06, w * 0.13, w * 0.86, w * 0.94].enumerated() {
            let tall = h * (0.28 + CGFloat(i % 2) * 0.1)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: base, y: h * 0.12))
            path.addCurve(to: CGPoint(x: base + 10 * u, y: h * 0.12 + tall),
                          control1: CGPoint(x: base + 40 * u, y: h * 0.12 + tall * 0.35),
                          control2: CGPoint(x: base - 40 * u, y: h * 0.12 + tall * 0.7))
            ctx.addPath(path)
            ctx.setStrokeColor(i % 2 == 0 ? rgb(0.1, 0.55, 0.3) : rgb(0.2, 0.65, 0.35))
            ctx.setLineWidth(12 * u)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
        // 泡
        for _ in 0..<26 {
            let p = CGPoint(x: rand.next() * w, y: h * 0.15 + rand.next() * h * 0.8)
            let s = (6 + rand.next() * 20) * u
            ctx.setStrokeColor(rgb(1, 1, 1, 0.55))
            ctx.setLineWidth(1.6 * u)
            ctx.strokeEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
            ctx.setFillColor(rgb(1, 1, 1, 0.5))
            ctx.fillEllipse(in: CGRect(x: p.x - s * 0.25, y: p.y + s * 0.1, width: s * 0.18, height: s * 0.18))
        }
        // 小さな魚の群れ（三角の尾と楕円）
        for _ in 0..<5 {
            let p = CGPoint(x: rand.next() * w, y: h * 0.55 + rand.next() * h * 0.35)
            let s = (14 + rand.next() * 10) * u
            ctx.setFillColor(rgb(1, 0.6, 0.2, 0.9))
            ctx.fillEllipse(in: CGRect(x: p.x - s, y: p.y - s * 0.4, width: s * 2, height: s * 0.8))
            ctx.move(to: CGPoint(x: p.x + s * 0.8, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x + s * 1.5, y: p.y + s * 0.5))
            ctx.addLine(to: CGPoint(x: p.x + s * 1.5, y: p.y - s * 0.5))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    // MARK: 教室：クリーム色の壁、木の枠の黒板とチョークの落書き、時計、木の床

    private static func classroom(_ ctx: CGContext, _ r: CGRect) {
        let w = r.width, h = r.height, u = min(w, h) / 540
        let floorTop = h * 0.2
        // 壁
        vertical(ctx, CGRect(x: 0, y: floorTop, width: w, height: h - floorTop),
                 top: rgb(0.93, 0.89, 0.78), bottom: rgb(0.82, 0.76, 0.62))
        // 床（木の板）
        vertical(ctx, CGRect(x: 0, y: 0, width: w, height: floorTop), top: rgb(0.62, 0.42, 0.24), bottom: rgb(0.42, 0.27, 0.14))
        ctx.setStrokeColor(rgb(0.3, 0.18, 0.08, 0.5))
        ctx.setLineWidth(2 * u)
        var y = floorTop
        var k: CGFloat = 0
        while y > 0 {
            y -= 16 * u + k * 4 * u
            k += 1
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.strokePath()
        // 幅木
        ctx.setFillColor(rgb(0.45, 0.3, 0.18))
        ctx.fill(CGRect(x: 0, y: floorTop, width: w, height: 12 * u))
        // 黒板（木の枠）
        let board = CGRect(x: w * 0.06, y: h * 0.5, width: w * 0.88, height: h * 0.3)
        ctx.setFillColor(rgb(0.55, 0.36, 0.2))
        ctx.fill(board.insetBy(dx: -12 * u, dy: -12 * u))
        ctx.saveGState()
        ctx.clip(to: board)
        vertical(ctx, board, top: rgb(0.13, 0.33, 0.25), bottom: rgb(0.08, 0.24, 0.18))
        // 消し残りのもや
        glow(ctx, at: CGPoint(x: board.midX - board.width * 0.2, y: board.midY), radius: board.width * 0.3,
             color: rgb(1, 1, 1, 0.07))
        ctx.restoreGState()
        // チョーク受け
        ctx.setFillColor(rgb(0.45, 0.29, 0.16))
        ctx.fill(CGRect(x: board.minX - 12 * u, y: board.minY - 22 * u, width: board.width + 24 * u, height: 10 * u))
        ctx.setFillColor(rgb(1, 1, 1, 0.9))
        ctx.fill(CGRect(x: board.minX + 30 * u, y: board.minY - 15 * u, width: 26 * u, height: 6 * u))
        ctx.setFillColor(rgb(1, 0.6, 0.6, 0.9))
        ctx.fill(CGRect(x: board.minX + 64 * u, y: board.minY - 15 * u, width: 22 * u, height: 6 * u))
        // チョークの落書き（式のような線、丸、星、花丸）
        ctx.setStrokeColor(rgb(1, 1, 1, 0.82))
        ctx.setLineWidth(3.5 * u)
        ctx.setLineCap(.round)
        let bx = board.minX + 28 * u, by = board.maxY - 40 * u
        // 「1 + 1 = 」の形
        ctx.move(to: CGPoint(x: bx, y: by + 12 * u)); ctx.addLine(to: CGPoint(x: bx, y: by - 14 * u))
        ctx.move(to: CGPoint(x: bx + 20 * u, y: by)); ctx.addLine(to: CGPoint(x: bx + 40 * u, y: by))
        ctx.move(to: CGPoint(x: bx + 30 * u, y: by + 10 * u)); ctx.addLine(to: CGPoint(x: bx + 30 * u, y: by - 10 * u))
        ctx.move(to: CGPoint(x: bx + 54 * u, y: by + 12 * u)); ctx.addLine(to: CGPoint(x: bx + 54 * u, y: by - 14 * u))
        ctx.move(to: CGPoint(x: bx + 70 * u, y: by + 4 * u)); ctx.addLine(to: CGPoint(x: bx + 90 * u, y: by + 4 * u))
        ctx.move(to: CGPoint(x: bx + 70 * u, y: by - 4 * u)); ctx.addLine(to: CGPoint(x: bx + 90 * u, y: by - 4 * u))
        // 波線の文
        for row in 0..<3 {
            let ly = board.maxY - (80 + CGFloat(row) * 30) * u
            ctx.move(to: CGPoint(x: bx, y: ly))
            var x = bx
            while x < board.minX + board.width * (row == 2 ? 0.4 : 0.55) {
                ctx.addQuadCurve(to: CGPoint(x: x + 16 * u, y: ly), control: CGPoint(x: x + 8 * u, y: ly + 8 * u))
                x += 16 * u
            }
        }
        ctx.strokePath()
        // 右の花丸
        let flower = CGPoint(x: board.maxX - board.width * 0.2, y: board.midY + 6 * u)
        ctx.setStrokeColor(rgb(1, 0.65, 0.65, 0.9))
        for i in 0..<3 {
            let s = (26 + CGFloat(i) * 14) * u
            ctx.strokeEllipse(in: CGRect(x: flower.x - s, y: flower.y - s * 0.9, width: s * 2, height: s * 1.8))
        }
        // 時計
        let clock = CGPoint(x: w * 0.5, y: h * 0.9)
        let cr = 28 * u
        ctx.setFillColor(rgb(0.25, 0.25, 0.28))
        ctx.fillEllipse(in: CGRect(x: clock.x - cr - 4 * u, y: clock.y - cr - 4 * u, width: (cr + 4 * u) * 2, height: (cr + 4 * u) * 2))
        ctx.setFillColor(rgb(1, 1, 0.97))
        ctx.fillEllipse(in: CGRect(x: clock.x - cr, y: clock.y - cr, width: cr * 2, height: cr * 2))
        ctx.setStrokeColor(rgb(0.15, 0.15, 0.18))
        ctx.setLineWidth(3 * u)
        ctx.move(to: clock); ctx.addLine(to: CGPoint(x: clock.x, y: clock.y + cr * 0.7))
        ctx.move(to: clock); ctx.addLine(to: CGPoint(x: clock.x + cr * 0.5, y: clock.y - cr * 0.2))
        ctx.strokePath()
        // 天井の影（上を少し暗く）
        linear(ctx, from: CGPoint(x: 0, y: h), to: CGPoint(x: 0, y: h * 0.75), colors: [rgb(0, 0, 0, 0.25), rgb(0, 0, 0, 0)])
    }

    // MARK: ステージ：赤い幕、板の床、上からのスポットライトと色のついた光

    private static func stage(_ ctx: CGContext, _ r: CGRect) {
        let w = r.width, h = r.height, u = min(w, h) / 540
        let floorTop = h * 0.22
        // 奥の幕（縦のひだを明暗の帯で）
        vertical(ctx, CGRect(x: 0, y: floorTop, width: w, height: h - floorTop), top: rgb(0.35, 0.02, 0.05), bottom: rgb(0.55, 0.05, 0.08))
        let folds = 12
        for i in 0..<folds {
            let x0 = w * CGFloat(i) / CGFloat(folds), fw = w / CGFloat(folds)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x0, y: floorTop, width: fw, height: h - floorTop))
            linearH(ctx, x0: x0, x1: x0 + fw, colors: [rgb(0, 0, 0, 0.4), rgb(1, 0.4, 0.4, 0.12), rgb(0, 0, 0, 0.4)])
            ctx.restoreGState()
        }
        // 床（暗い板）と、手前のふち
        vertical(ctx, CGRect(x: 0, y: 0, width: w, height: floorTop), top: rgb(0.28, 0.17, 0.1), bottom: rgb(0.1, 0.06, 0.04))
        ctx.setStrokeColor(rgb(0, 0, 0, 0.35))
        ctx.setLineWidth(1.5 * u)
        for i in 1..<10 {
            let x = w * CGFloat(i) / 10
            ctx.move(to: CGPoint(x: w / 2 + (x - w / 2) * 0.6, y: floorTop))
            ctx.addLine(to: CGPoint(x: w / 2 + (x - w / 2) * 1.4, y: 0))
        }
        ctx.strokePath()
        // 色のついた光（左上から青紫、右上から桃色）
        beam(ctx, from: CGPoint(x: -w * 0.05, y: h), to: CGPoint(x: w * 0.55, y: floorTop), spread: w * 0.22,
             color: rgb(0.4, 0.35, 1, 0.3))
        beam(ctx, from: CGPoint(x: w * 1.05, y: h), to: CGPoint(x: w * 0.45, y: floorTop), spread: w * 0.22,
             color: rgb(1, 0.3, 0.7, 0.3))
        // 真ん中のスポットライト
        beam(ctx, from: CGPoint(x: w * 0.5, y: h), to: CGPoint(x: w * 0.5, y: floorTop * 0.75), spread: w * 0.34,
             color: rgb(1, 0.95, 0.75, 0.42))
        // 床に落ちた光の輪
        ctx.saveGState()
        ctx.translateBy(x: w * 0.5, y: floorTop * 0.7)
        ctx.scaleBy(x: 1, y: 0.25)
        glow(ctx, at: .zero, radius: w * 0.42, color: rgb(1, 0.95, 0.75, 0.65))
        ctx.restoreGState()
        // 上の飾り幕（波形のふち）
        let valance = CGMutablePath()
        let vh = h * 0.08
        valance.move(to: CGPoint(x: 0, y: h))
        valance.addLine(to: CGPoint(x: 0, y: h - vh))
        let swags = 5
        for i in 0..<swags {
            let x0 = w * CGFloat(i) / CGFloat(swags), x1 = w * CGFloat(i + 1) / CGFloat(swags)
            valance.addQuadCurve(to: CGPoint(x: x1, y: h - vh), control: CGPoint(x: (x0 + x1) / 2, y: h - vh * 1.8))
        }
        valance.addLine(to: CGPoint(x: w, y: h))
        valance.closeSubpath()
        ctx.addPath(valance)
        ctx.setFillColor(rgb(0.5, 0.03, 0.06))
        ctx.fillPath()
        ctx.addPath(valance)
        ctx.setStrokeColor(rgb(0.95, 0.75, 0.3))
        ctx.setLineWidth(4 * u)
        ctx.strokePath()
        // 左右の袖幕
        for side in [0, 1] {
            let x = side == 0 ? 0 : w * 0.9
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x, y: floorTop * 0.6, width: w * 0.1, height: h))
            linearH(ctx, x0: x, x1: x + w * 0.1, colors: side == 0
                    ? [rgb(0.3, 0.01, 0.03), rgb(0.6, 0.06, 0.1)]
                    : [rgb(0.6, 0.06, 0.1), rgb(0.3, 0.01, 0.03)])
            ctx.restoreGState()
        }
        // 光の中に舞うほこり
        var rand = Seeded(41)
        for _ in 0..<40 {
            let p = CGPoint(x: w * (0.3 + rand.next() * 0.4), y: floorTop + rand.next() * (h - floorTop) * 0.8)
            let s = (1 + rand.next() * 2.5) * u
            ctx.setFillColor(rgb(1, 1, 0.9, 0.3 + rand.next() * 0.4))
            ctx.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
        }
    }

    // MARK: 描く道具

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func gradient(_ colors: [CGColor]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)
    }

    /// rect を上から下へ塗り分ける
    private static func vertical(_ ctx: CGContext, _ rect: CGRect, top: CGColor, bottom: CGColor) {
        ctx.saveGState()
        ctx.clip(to: rect)
        linear(ctx, from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY), colors: [top, bottom])
        ctx.restoreGState()
    }

    private static func linear(_ ctx: CGContext, from: CGPoint, to: CGPoint, colors: [CGColor]) {
        guard let g = gradient(colors) else { return }
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 左から右へ（いまの切り抜きの中だけ）
    private static func linearH(_ ctx: CGContext, x0: CGFloat, x1: CGFloat, colors: [CGColor]) {
        guard let g = gradient(colors) else { return }
        ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
    }

    private static func radial(_ ctx: CGContext, from: CGPoint, to: CGPoint, radius: CGFloat, colors: [CGColor]) {
        guard let g = gradient(colors) else { return }
        ctx.drawRadialGradient(g, startCenter: from, startRadius: 0, endCenter: to, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    }

    /// 真ん中が濃く、外へ消えていく丸い光
    private static func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, color: CGColor) {
        guard let g = gradient([color, color.copy(alpha: 0) ?? color]) else { return }
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }

    /// 上の一点から下へ広がる光の筋
    private static func beam(_ ctx: CGContext, from: CGPoint, to: CGPoint, spread: CGFloat, color: CGColor) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(hypot(dx, dy), 1)
        // 進む向きに直角な向き
        let nx = -dy / len * spread, ny = dx / len * spread
        let path = CGMutablePath()
        path.move(to: CGPoint(x: from.x - nx * 0.08, y: from.y - ny * 0.08))
        path.addLine(to: CGPoint(x: from.x + nx * 0.08, y: from.y + ny * 0.08))
        path.addLine(to: CGPoint(x: to.x + nx, y: to.y + ny))
        path.addLine(to: CGPoint(x: to.x - nx, y: to.y - ny))
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        linear(ctx, from: from, to: to, colors: [color, color.copy(alpha: (color.alpha) * 0.25) ?? color])
        ctx.restoreGState()
    }

    /// 決まった種から 0〜1 の数を出す（毎回同じ並びになる）
    private struct Seeded {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Double(state >> 11) / 9_007_199_254_740_992.0)
        }
    }
}
