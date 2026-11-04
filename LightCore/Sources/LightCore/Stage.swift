import Foundation

public enum LightColor: String, Codable, Sendable {
    case white, red, green, blue
}

/// ステージ1つ分。JSON で書く。座標は幅 1000 × 高さ 1400 が既定で、y が上
public struct Stage: Codable, Sendable {
    public var id: String
    public var title: String
    public var width: Double
    public var height: Double
    public var hinge: HingeMirror
    public var emitters: [Emitter]
    public var mirrors: [Mirror]
    public var blocks: [Wall]
    public var filters: [Filter]
    public var prisms: [Prism]
    public var targets: [Target]

    public init(id: String, title: String, width: Double = 1000, height: Double = 1400,
                hinge: HingeMirror, emitters: [Emitter], mirrors: [Mirror] = [], blocks: [Wall] = [],
                filters: [Filter] = [], prisms: [Prism] = [], targets: [Target]) {
        self.id = id
        self.title = title
        self.width = width
        self.height = height
        self.hinge = hinge
        self.emitters = emitters
        self.mirrors = mirrors
        self.blocks = blocks
        self.filters = filters
        self.prisms = prisms
        self.targets = targets
    }

    enum CodingKeys: String, CodingKey {
        case id, title, width, height, hinge, emitters, mirrors, blocks, filters, prisms, targets
    }

    // JSON では大きさと空の配列を省略できる
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1000,
            height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 1400,
            hinge: try c.decode(HingeMirror.self, forKey: .hinge),
            emitters: try c.decode([Emitter].self, forKey: .emitters),
            mirrors: try c.decodeIfPresent([Mirror].self, forKey: .mirrors) ?? [],
            blocks: try c.decodeIfPresent([Wall].self, forKey: .blocks) ?? [],
            filters: try c.decodeIfPresent([Filter].self, forKey: .filters) ?? [],
            prisms: try c.decodeIfPresent([Prism].self, forKey: .prisms) ?? [],
            targets: try c.decode([Target].self, forKey: .targets)
        )
    }
}

/// 折り目にある鏡。傾き = baseDegrees + (開き角度 − centerHinge) × gain
public struct HingeMirror: Codable, Sendable {
    public var center: Vec
    public var length: Double
    public var baseDegrees: Double
    public var centerHinge: Double
    public var gain: Double
    /// 遊ぶ範囲。内側の画面のまま、閉じる方向へ寄りすぎない（実機では 40〜50° で外側の画面に切り替わる）
    public var minHinge: Double
    public var maxHinge: Double

    public init(center: Vec, length: Double, baseDegrees: Double, centerHinge: Double = 122.5,
                gain: Double = 1, minHinge: Double = 70, maxHinge: Double = 175) {
        self.center = center
        self.length = length
        self.baseDegrees = baseDegrees
        self.centerHinge = centerHinge
        self.gain = gain
        self.minHinge = minHinge
        self.maxHinge = maxHinge
    }

    enum CodingKeys: String, CodingKey {
        case center, length, baseDegrees, centerHinge, gain, minHinge, maxHinge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            center: try c.decode(Vec.self, forKey: .center),
            length: try c.decode(Double.self, forKey: .length),
            baseDegrees: try c.decode(Double.self, forKey: .baseDegrees),
            centerHinge: try c.decodeIfPresent(Double.self, forKey: .centerHinge) ?? 122.5,
            gain: try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1,
            minHinge: try c.decodeIfPresent(Double.self, forKey: .minHinge) ?? 70,
            maxHinge: try c.decodeIfPresent(Double.self, forKey: .maxHinge) ?? 175
        )
    }

    public func degrees(atHinge hinge: Double) -> Double {
        let clamped = min(max(hinge, minHinge), maxHinge)
        return baseDegrees + (clamped - centerHinge) * gain
    }

    public func segment(atHinge hinge: Double) -> Segment {
        Segment(center: center, length: length, degrees: degrees(atHinge: hinge))
    }
}

public struct Emitter: Codable, Sendable {
    public var position: Vec
    public var degrees: Double
    public var color: LightColor?

    public init(position: Vec, degrees: Double, color: LightColor? = nil) {
        self.position = position
        self.degrees = degrees
        self.color = color
    }
}

/// 両面が鏡の板。movable なら指で向きを変えられる（step 度刻み）
public struct Mirror: Codable, Sendable {
    public var center: Vec
    public var length: Double
    public var degrees: Double
    public var movable: Bool?
    public var step: Double?

    public init(center: Vec, length: Double, degrees: Double, movable: Bool? = nil, step: Double? = nil) {
        self.center = center
        self.length = length
        self.degrees = degrees
        self.movable = movable
        self.step = step
    }

    public var segment: Segment { Segment(center: center, length: length, degrees: degrees) }
}

/// 光を止める壁
public struct Wall: Codable, Sendable {
    public var a: Vec
    public var b: Vec

    public init(a: Vec, b: Vec) {
        self.a = a
        self.b = b
    }
}

/// 同じ色（または白）の光だけ通し、通った光をその色にする
public struct Filter: Codable, Sendable {
    public var a: Vec
    public var b: Vec
    public var color: LightColor

    public init(a: Vec, b: Vec, color: LightColor) {
        self.a = a
        self.b = b
        self.color = color
    }
}

/// 当たった光を、中心から ±spread 度の2本に分ける
public struct Prism: Codable, Sendable {
    public var center: Vec
    public var radius: Double
    public var spread: Double

    public init(center: Vec, radius: Double, spread: Double = 30) {
        self.center = center
        self.radius = radius
        self.spread = spread
    }
}

/// 光が当たると点く。color があればその色の光でだけ点く
public struct Target: Codable, Sendable {
    public var center: Vec
    public var radius: Double
    public var color: LightColor?

    public init(center: Vec, radius: Double, color: LightColor? = nil) {
        self.center = center
        self.radius = radius
        self.color = color
    }
}
