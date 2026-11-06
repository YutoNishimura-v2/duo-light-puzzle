import CoreImage
import CoreVideo
import Foundation

/// 内側のカメラの映像を、画面の左上の小窓（BeReal の自撮りの窓）用に小さくする。
/// カメラの処理の列から呼ばれる。1 秒に 12 枚まで
final class WipeFeed: @unchecked Sendable {
    /// しばりの処理と同じ描き手を使う（描き手ごとに GPU の作業場を持つので、増やさない）
    private let context = EffectEngine.sharedContext
    private var last: TimeInterval = 0
    var onImage: (@MainActor (CGImage) -> Void)?

    func process(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= 1.0 / 12 else { return }
        last = now
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = 360 / max(image.extent.width, image.extent.height, 1)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(small, from: small.extent.integral) else { return }
            Task { @MainActor [onImage] in onImage?(cg) }
        }
    }
}
