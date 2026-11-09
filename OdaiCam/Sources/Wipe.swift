import CoreImage
import CoreVideo
import Foundation

/// カメラの映像を、画面に出す絵（CGImage）にする。カメラの処理の列から呼ばれる。
/// 内側のカメラは左上の小窓（BeReal の自撮りの窓）用に小さく、
/// 背面のカメラはしばりなしのときにファインダーへ全身を収めて出す用に使う
final class WipeFeed: @unchecked Sendable {
    /// しばりの処理と同じ描き手を使う（描き手ごとに GPU の作業場を持つので、増やさない）
    private let context = EffectEngine.sharedContext
    private let fps: Double
    private let longSide: CGFloat
    private var last: TimeInterval = 0
    /// main に渡した絵がまだ受け取られていない（lock で守る）。main が詰まったら新しい絵を作らない
    private let lock = NSLock()
    private var inFlight = false
    private var enabled = true
    var onImage: (@MainActor (CGImage) -> Void)?

    /// - Parameters:
    ///   - fps: 1 秒に作る絵の数の上限
    ///   - longSide: 作る絵の長い辺（点）
    init(fps: Double = 12, longSide: CGFloat = 360) {
        self.fps = fps
        self.longSide = longSide
    }

    /// 絵を作るかどうか（しばりの処理が画面を描いている間は止める）
    func setEnabled(_ on: Bool) {
        lock.withLock { enabled = on }
    }

    func process(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= 1.0 / fps else { return }
        let go: Bool = lock.withLock {
            if inFlight || !enabled { return false }
            inFlight = true
            return true
        }
        guard go else { return }
        last = now
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, longSide / max(image.extent.width, image.extent.height, 1))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(small, from: small.extent.integral) else {
                lock.withLock { inFlight = false }
                return
            }
            Task { @MainActor [onImage, weak self] in
                onImage?(cg)
                self?.delivered()
            }
        }
    }

    /// main が絵を受け取った
    private func delivered() {
        lock.withLock { inFlight = false }
    }
}
