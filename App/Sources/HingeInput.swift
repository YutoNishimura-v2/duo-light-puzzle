import Foundation
import Observation
import SwiftUI

/// 開き角度の入力。本物のヒンジ（onHingeChange）か、ヒンジのない端末ではスライダー。
///
/// 実機（HingeLab で確認）では、更新は動かしている間だけ来る（最大 26 回/秒、刻み 0.06° ほど）。
/// 止めると更新が来ないので最後の値を持ち続け、なめらかにする処理はタイマーで進める。
@MainActor
@Observable
final class HingeInput {
    enum Availability {
        case waiting, available, unavailable
    }

    private(set) var availability = Availability.waiting
    /// 届いた生の値
    private(set) var raw: Double?
    /// 画面と判定に使う、少しなめらかにした値
    private(set) var smoothed: Double?

    var useSlider = false
    var sliderAngle = 122.5

    var usingSlider: Bool { useSlider || availability == .unavailable }
    var angle: Double? { usingSlider ? sliderAngle : smoothed }

    /// なめらかにする時定数（秒）。振動で本体が震えたときの小さなブレを消す程度
    static let smoothing = 0.05

    @ObservationIgnored private var lastTick = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.tick()
            }
        }
    }

    func receive(degrees: Double?) {
        guard let degrees else {
            availability = .unavailable
            raw = nil
            smoothed = nil
            return
        }
        availability = .available
        raw = degrees
        if smoothed == nil { smoothed = degrees }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        guard let raw, let current = smoothed else { return }
        let next = current + (raw - current) * (1 - exp(-dt / Self.smoothing))
        // 差が十分小さければ止める（無駄な再描画をしない）
        if abs(next - current) > 0.001 { smoothed = next } else if current != raw { smoothed = raw }
    }
}

extension View {
    /// Apple の onHingeChange（iOS 27.1）を HingeInput へ流す。アプリでこの API に触るのはここだけ
    func hingeUpdates(into input: HingeInput) -> some View {
        onHingeChange { _, newContext in
            let degrees = newContext.hinge?.angle.degrees
            if Thread.isMainThread {
                MainActor.assumeIsolated { input.receive(degrees: degrees) }
            } else {
                Task { @MainActor in input.receive(degrees: degrees) }
            }
        }
    }
}
