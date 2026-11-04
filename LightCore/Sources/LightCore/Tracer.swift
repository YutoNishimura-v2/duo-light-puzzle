import Foundation

public struct Beam: Sendable {
    public var points: [Vec]
    public var color: LightColor
}

public struct TraceResult: Sendable {
    public var beams: [Beam]
    public var litTargets: Set<Int>
    public var allLit: Bool
}

/// 光を飛ばして、どの的が点くかを求める
public enum Tracer {
    /// 1本の光が反射・分岐できる回数の上限（鏡の間で往復し続けるのを止める）
    public static let maxBounces = 32
    /// 光線の総数の上限（プリズムで増えすぎないように）
    public static let maxBeams = 64

    private enum Hit {
        case reflect(normal: Vec)
        case stop
        case target(Int)
        case filter(LightColor)
        case prism(Int)
    }

    private struct Ray {
        var origin: Vec
        var dir: Vec
        var color: LightColor
        var depth: Int
        /// 出てきたばかりのプリズム（すぐ当たり直さないよう除く）
        var skipPrism: Int?
    }

    /// mirrorDegrees で、動かせる鏡の向きを上書きする（キーは mirrors の添字）
    public static func trace(_ stage: Stage, hinge: Double, mirrorDegrees: [Int: Double] = [:]) -> TraceResult {
        var mirrors = stage.mirrors.enumerated().map { i, m -> Segment in
            var m = m
            if let d = mirrorDegrees[i] { m.degrees = d }
            return m.segment
        }
        mirrors.append(stage.hinge.segment(atHinge: hinge))
        let w = stage.width, h = stage.height
        let bounds = [
            Segment(Vec(0, 0), Vec(w, 0)), Segment(Vec(w, 0), Vec(w, h)),
            Segment(Vec(w, h), Vec(0, h)), Segment(Vec(0, h), Vec(0, 0)),
        ]
        let walls = stage.blocks.map { Segment($0.a, $0.b) } + bounds
        let filters = stage.filters.map { (Segment($0.a, $0.b), $0.color) }

        var queue = stage.emitters.map {
            Ray(origin: $0.position, dir: Vec(degrees: $0.degrees), color: $0.color ?? .white, depth: 0, skipPrism: nil)
        }
        var beams: [Beam] = []
        var lit = Set<Int>()

        while !queue.isEmpty && beams.count < maxBeams {
            var ray = queue.removeFirst()
            var points = [ray.origin]
            tracing: while ray.depth <= maxBounces {
                var best: (t: Double, hit: Hit)?
                func consider(_ t: Double?, _ hit: Hit) {
                    if let t, t < (best?.t ?? .infinity) { best = (t, hit) }
                }
                for m in mirrors { consider(m.hit(origin: ray.origin, dir: ray.dir), .reflect(normal: m.normal)) }
                for s in walls { consider(s.hit(origin: ray.origin, dir: ray.dir), .stop) }
                for (s, c) in filters { consider(s.hit(origin: ray.origin, dir: ray.dir), .filter(c)) }
                for (i, t) in stage.targets.enumerated() {
                    consider(hitCircle(center: t.center, radius: t.radius, origin: ray.origin, dir: ray.dir), .target(i))
                }
                for (i, p) in stage.prisms.enumerated() where i != ray.skipPrism {
                    consider(hitCircle(center: p.center, radius: p.radius, origin: ray.origin, dir: ray.dir), .prism(i))
                }
                guard let best else { break }
                let point = ray.origin + ray.dir * best.t

                switch best.hit {
                case .reflect(let n):
                    points.append(point)
                    ray.dir = ray.dir.reflected(normal: n).normalized
                    ray.origin = point + ray.dir * 1e-6
                    ray.skipPrism = nil
                    ray.depth += 1
                case .stop:
                    points.append(point)
                    break tracing
                case .target(let i):
                    points.append(point)
                    let want = stage.targets[i].color
                    if want == nil || want == ray.color { lit.insert(i) }
                    break tracing
                case .filter(let c):
                    points.append(point)
                    guard ray.color == .white || ray.color == c else { break tracing }
                    // 色が変わるので、ここで光線を区切る
                    beams.append(Beam(points: points, color: ray.color))
                    points = [point]
                    ray.color = c
                    ray.origin = point + ray.dir * 1e-6
                    ray.depth += 1
                case .prism(let i):
                    let prism = stage.prisms[i]
                    points.append(prism.center)
                    for sign in [-1.0, 1.0] {
                        queue.append(Ray(origin: prism.center, dir: Vec(degrees: ray.dir.degrees + sign * prism.spread),
                                         color: ray.color, depth: ray.depth + 1, skipPrism: i))
                    }
                    break tracing
                }
            }
            beams.append(Beam(points: points, color: ray.color))
        }
        return TraceResult(beams: beams, litTargets: lit,
                           allLit: !stage.targets.isEmpty && lit.count == stage.targets.count)
    }
}
