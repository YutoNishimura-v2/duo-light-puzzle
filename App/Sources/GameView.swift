import LightCore
import SwiftUI

struct GameView: View {
    let stages: [Stage]
    @State var index: Int
    @Bindable var input: HingeInput
    let record: PlayRecord
    @State private var model: GameModel?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.09).ignoresSafeArea()
            if let model {
                board(model)
                overlay(model)
            }
        }
        .navigationTitle(stages[index].title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("やり直す", systemImage: "arrow.counterclockwise") { model?.restart() }
        }
        .onAppear { load() }
        .onDisappear { model?.stop() }
    }

    private func load() {
        model?.stop()
        model = GameModel(stage: stages[index], input: input, record: record)
    }

    private func board(_ model: GameModel) -> some View {
        GeometryReader { geo in
            let map = BoardMapping(stage: model.stage, size: geo.size)
            // 描画は main actor の外で走るので、いまの状態を値で渡す
            let renderer = BoardRenderer(stage: model.stage, result: model.result, mirrorDegrees: model.mirrorDegrees,
                                         hinge: model.hinge, map: map)
            Canvas { context, _ in
                renderer.draw(in: &context)
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                if let i = map.movableMirror(near: point, in: model.stage) { model.rotateMirror(i) }
            }
        }
        .padding(8)
    }

    private func overlay(_ model: GameModel) -> some View {
        VStack {
            HStack {
                Text(String(format: "%.1f°", model.hinge))
                    .font(.system(.title3, design: .rounded).bold()).monospacedDigit()
                if input.usingSlider {
                    Text(input.availability == .unavailable ? "ヒンジなし" : "スライダー")
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.orange.opacity(0.3), in: Capsule())
                }
                Spacer()
                if model.holdProgress > 0 && !model.cleared {
                    ProgressView(value: model.holdProgress).frame(width: 80).tint(.yellow)
                }
            }
            .padding(.horizontal, 20)
            Spacer()
            if model.cleared {
                VStack(spacing: 12) {
                    Text("クリア").font(.largeTitle.bold())
                    if index + 1 < stages.count {
                        Button("次へ") {
                            index += 1
                            load()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                Spacer()
            }
            if input.usingSlider {
                Slider(value: $input.sliderAngle, in: model.stage.hinge.minHinge...model.stage.hinge.maxHinge)
                    .padding(.horizontal, 24)
            }
            if input.availability != .unavailable {
                Toggle("スライダーで試す", isOn: $input.useSlider)
                    .font(.caption).padding(.horizontal, 24).padding(.bottom, 8)
            }
        }
    }
}

/// ステージの座標（y が上）と画面の座標の変換
struct BoardMapping {
    let scale: Double
    let origin: CGPoint
    let stageHeight: Double

    init(stage: Stage, size: CGSize) {
        scale = min(size.width / stage.width, size.height / stage.height)
        origin = CGPoint(x: (size.width - stage.width * scale) / 2, y: (size.height - stage.height * scale) / 2)
        stageHeight = stage.height
    }

    func point(_ v: Vec) -> CGPoint {
        CGPoint(x: origin.x + v.x * scale, y: origin.y + (stageHeight - v.y) * scale)
    }

    func stagePoint(_ p: CGPoint) -> Vec {
        Vec((p.x - origin.x) / scale, stageHeight - (p.y - origin.y) / scale)
    }

    func movableMirror(near p: CGPoint, in stage: Stage) -> Int? {
        let v = stagePoint(p)
        let candidates = stage.mirrors.enumerated().filter { $0.element.movable == true }
        let nearest = candidates.min { ($0.element.center - v).length < ($1.element.center - v).length }
        guard let nearest, (nearest.element.center - v).length < nearest.element.length / 2 + 40 else { return nil }
        return nearest.offset
    }
}

struct BoardRenderer {
    let stage: Stage
    let result: TraceResult
    let mirrorDegrees: [Int: Double]
    let hinge: Double
    let map: BoardMapping

    func draw(in context: inout GraphicsContext) {
        let s = map.scale

        // 盤面と折り目
        let frame = CGRect(origin: map.origin, size: CGSize(width: stage.width * s, height: stage.height * s))
        context.fill(Path(roundedRect: frame, cornerRadius: 12), with: .color(.white.opacity(0.03)))
        var fold = Path()
        fold.move(to: map.point(Vec(0, stage.hinge.center.y)))
        fold.addLine(to: map.point(Vec(stage.width, stage.hinge.center.y)))
        context.stroke(fold, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))

        for wall in stage.blocks {
            context.stroke(line(wall.a, wall.b), with: .color(.gray), style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))
        }
        for filter in stage.filters {
            context.stroke(line(filter.a, filter.b), with: .color(color(filter.color).opacity(0.45)),
                           style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
        }
        for prism in stage.prisms {
            context.fill(circle(prism.center, prism.radius), with: .color(.white.opacity(0.25)))
        }

        // 光
        for beam in result.beams where beam.points.count >= 2 {
            var path = Path()
            path.move(to: map.point(beam.points[0]))
            for p in beam.points.dropFirst() { path.addLine(to: map.point(p)) }
            let c = color(beam.color)
            context.stroke(path, with: .color(c.opacity(0.25)), style: StrokeStyle(lineWidth: 12 * s, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round, lineJoin: .round))
        }

        for (i, target) in stage.targets.enumerated() {
            let lit = result.litTargets.contains(i)
            let c = target.color.map(color) ?? .yellow
            context.fill(circle(target.center, target.radius), with: .color(c.opacity(lit ? 0.9 : 0.12)))
            context.stroke(circle(target.center, target.radius), with: .color(c.opacity(0.8)), lineWidth: 2)
        }
        for emitter in stage.emitters {
            context.fill(circle(emitter.position, 22), with: .color(color(emitter.color ?? .white)))
        }

        for (i, mirror) in stage.mirrors.enumerated() {
            var m = mirror
            if let d = mirrorDegrees[i] { m.degrees = d }
            let seg = m.segment
            context.stroke(line(seg.a, seg.b), with: .color(Color(white: 0.85)), style: StrokeStyle(lineWidth: 8 * s, lineCap: .round))
            if mirror.movable == true {
                context.stroke(circle(mirror.center, mirror.length / 2 + 20), with: .color(.white.opacity(0.15)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        let hingeSeg = stage.hinge.segment(atHinge: hinge)
        context.stroke(line(hingeSeg.a, hingeSeg.b), with: .color(Color(red: 0.88, green: 0.65, blue: 0.23)),
                       style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))
        context.fill(circle(stage.hinge.center, 10), with: .color(.white))
    }

    private func line(_ a: Vec, _ b: Vec) -> Path {
        var p = Path()
        p.move(to: map.point(a))
        p.addLine(to: map.point(b))
        return p
    }

    private func circle(_ c: Vec, _ r: Double) -> Path {
        let center = map.point(c)
        let rr = r * map.scale
        return Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2))
    }

    private func color(_ c: LightColor) -> Color {
        switch c {
        case .white: Color(white: 0.95)
        case .red: Color(red: 1, green: 0.35, blue: 0.3)
        case .green: Color(red: 0.35, green: 0.95, blue: 0.45)
        case .blue: Color(red: 0.35, green: 0.6, blue: 1)
        }
    }
}
