import Foundation
import LightCore
import Observation
import UIKit

/// 1ステージ分の遊びの状態。開き角度を読んで光を飛ばし、すべての的を 0.5 秒保ったらクリア
@MainActor
@Observable
final class GameModel {
    let stage: Stage
    private let input: HingeInput
    private let record: PlayRecord

    /// 指で向きを変えた鏡（キーは stage.mirrors の添字）
    private(set) var mirrorDegrees: [Int: Double] = [:]
    private(set) var result: TraceResult
    private(set) var holdProgress = 0.0
    private(set) var cleared = false

    static let holdDuration = 0.5

    @ObservationIgnored private var holdStart: TimeInterval?
    @ObservationIgnored private var lastHinge: Double?
    @ObservationIgnored private let hitFeedback = UIImpactFeedbackGenerator(style: .soft)
    @ObservationIgnored private let clearFeedback = UINotificationFeedbackGenerator()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(stage: Stage, input: HingeInput, record: PlayRecord) {
        self.stage = stage
        self.input = input
        self.record = record
        result = Tracer.trace(stage, hinge: input.angle ?? stage.hinge.centerHinge)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.tick()
            }
        }
    }

    func stop() {
        ticker?.cancel()
    }

    var hinge: Double { input.angle ?? stage.hinge.centerHinge }

    /// 動かせる鏡を step 度回す
    func rotateMirror(_ index: Int) {
        guard !cleared, stage.mirrors.indices.contains(index), stage.mirrors[index].movable == true else { return }
        let m = stage.mirrors[index]
        let current = mirrorDegrees[index] ?? m.degrees
        mirrorDegrees[index] = (current + (m.step ?? 15)).truncatingRemainder(dividingBy: 180)
        retrace()
    }

    func restart() {
        mirrorDegrees = [:]
        cleared = false
        holdStart = nil
        holdProgress = 0
        retrace()
    }

    private func tick() {
        guard !cleared else { return }
        if hinge != lastHinge {
            lastHinge = hinge
            retrace()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard result.allLit else {
            holdStart = nil
            holdProgress = 0
            return
        }
        let start = holdStart ?? now
        holdStart = start
        holdProgress = min(1, (now - start) / Self.holdDuration)
        if holdProgress >= 1 {
            cleared = true
            record.markCleared(stage.id)
            clearFeedback.notificationOccurred(.success)
        }
    }

    private func retrace() {
        let before = result.litTargets
        result = Tracer.trace(stage, hinge: hinge, mirrorDegrees: mirrorDegrees)
        // 振動は「新しく的に当たった」ときだけ。角度の目盛りごとには鳴らさない（本体が震えて値がブレるため）
        if !result.litTargets.subtracting(before).isEmpty && holdStart == nil {
            hitFeedback.impactOccurred(intensity: 0.6)
        }
    }
}

/// クリアしたステージを端末に残す
@MainActor
@Observable
final class PlayRecord {
    private(set) var cleared: Set<String>
    private static let key = "clearedStages"

    init() {
        cleared = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func markCleared(_ id: String) {
        cleared.insert(id)
        UserDefaults.standard.set(Array(cleared), forKey: Self.key)
    }
}
