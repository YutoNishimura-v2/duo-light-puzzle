import Foundation

/// 同梱のステージ（Stages/stageNN.json）を番号順に読む
public enum StageCatalog {
    /// 無料で遊べるステージ数。残りは買い切りで解放
    public static let freeCount = 3

    public static func load() throws -> [Stage] {
        guard let dir = Bundle.module.resourceURL?.appendingPathComponent("Stages") else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { try JSONDecoder().decode(Stage.self, from: Data(contentsOf: $0)) }
    }

    /// 開き角度を step 度ずつ動かして、すべての的が点く角度の範囲（連続した区間）を返す。ステージ作りの確認用
    public static func solutionRanges(_ stage: Stage, step: Double = 0.1) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var start: Double?
        var last = stage.hinge.minHinge
        var hinge = stage.hinge.minHinge
        while hinge <= stage.hinge.maxHinge + 1e-9 {
            if Tracer.trace(stage, hinge: hinge).allLit {
                if start == nil { start = hinge }
                last = hinge
            } else if let s = start {
                ranges.append(s...last)
                start = nil
            }
            hinge += step
        }
        if let s = start { ranges.append(s...last) }
        return ranges
    }
}
