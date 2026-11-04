import Foundation

/// 2D のベクトル。座標は数学の向き（y が上）。画面に描くときに反転する
public struct Vec: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// 角度（度、x 軸から反時計回り）の向きの単位ベクトル
    public init(degrees: Double) {
        let r = degrees * .pi / 180
        self.init(cos(r), sin(r))
    }

    public static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec, k: Double) -> Vec { Vec(a.x * k, a.y * k) }
    public func dot(_ o: Vec) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec) -> Double { x * o.y - y * o.x }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec { self * (1 / length) }
    public var degrees: Double { atan2(y, x) * 180 / .pi }

    /// 法線 n の面で反射した向き
    public func reflected(normal n: Vec) -> Vec { self - n * (2 * dot(n)) }
}

public struct Segment: Hashable, Sendable {
    public var a: Vec
    public var b: Vec

    public init(_ a: Vec, _ b: Vec) {
        self.a = a
        self.b = b
    }

    /// 中心・長さ・向き（度）から
    public init(center: Vec, length: Double, degrees: Double) {
        let half = Vec(degrees: degrees) * (length / 2)
        self.init(center - half, center + half)
    }

    public var normal: Vec {
        let d = (b - a).normalized
        return Vec(-d.y, d.x)
    }

    /// 光線 origin + t·dir（t > 0）との交点までの t。当たらなければ nil
    public func hit(origin: Vec, dir: Vec) -> Double? {
        let s = b - a
        let denom = dir.cross(s)
        guard abs(denom) > 1e-12 else { return nil }
        let w = a - origin
        let t = w.cross(s) / denom
        let u = w.cross(dir) / denom
        guard t > 1e-9, u >= 0, u <= 1 else { return nil }
        return t
    }
}

/// 光線が円に外から入る点までの t。円の中から出る光には nil
func hitCircle(center: Vec, radius: Double, origin: Vec, dir: Vec) -> Double? {
    let oc = origin - center
    let c = oc.dot(oc) - radius * radius
    guard c > 0 else { return nil }
    let b = oc.dot(dir)
    let disc = b * b - c
    guard disc >= 0 else { return nil }
    let t = -b - disc.squareRoot()
    return t > 1e-9 ? t : nil
}
