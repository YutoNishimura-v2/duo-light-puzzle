import UIKit

/// 見比べの画像：同じ人・同じポーズを、そのまま／棒人間／モザイク（3 段）／着ぐるみで並べて書き出す。
/// デモで起動したときだけ、Documents/compare に作る（CI がそこから取り出して本人に見せる）
enum CompareShots {
    /// ポーズの時刻（デモの役者の動きの中から 3 つ）
    static let times: [Double] = [1.5, 4.2, 7.0]

    static func make() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("compare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = EffectEngine()
        let saved = EffectEngine.mosaicLevel
        defer { EffectEngine.mosaicLevel = saved }

        for (i, t) in times.enumerated() {
            guard let source = FakeCamera.demoFrame(at: t) else { continue }
            var panels: [(String, CGImage)] = []
            func add(_ title: String, _ effect: Effect?) {
                // 1 枚ごとに一時的な絵を手放す（手放さないと型抜きの画素の箱が足りなくなり、影絵が真っ黒になった）
                autoreleasepool {
                    if let image = engine.still(effect, source: source, frameTime: t) { panels.append((title, image)) }
                }
            }
            add("そのまま", nil)
            add("棒人間", .stick)
            for level in MosaicLevel.allCases {
                EffectEngine.mosaicLevel = level
                add("モザイク（\(level.name)）", .mosaic)
            }
            EffectEngine.mosaicLevel = .normal
            add("着ぐるみ", .costume)
            add("影絵", .silhouette)
            for (title, image) in panels {
                write(UIImage(cgImage: image), to: dir.appendingPathComponent("pose\(i + 1)-\(title).png"))
            }
            // 本人に見せる 4 枚（そのまま・棒人間・モザイク（ふつう）・着ぐるみ）を 2×2 に
            let four = panels.filter { ["そのまま", "棒人間", "モザイク（ふつう）", "着ぐるみ"].contains($0.0) }
            if let sheet = sheet(four, columns: 2) { write(sheet, to: dir.appendingPathComponent("pose\(i + 1)-4modes.png")) }
            if let row = sheet(panels, columns: panels.count) { write(row, to: dir.appendingPathComponent("pose\(i + 1)-all.png")) }
        }
        CrashLog.mark("見比べの画像を書き出した")
    }

    private static func write(_ image: UIImage, to url: URL) {
        try? image.pngData()?.write(to: url)
    }

    /// 見出しつきで並べる
    private static func sheet(_ panels: [(String, CGImage)], columns: Int) -> UIImage? {
        guard let first = panels.first?.1, columns > 0 else { return nil }
        let pw = CGFloat(first.width) / 2, ph = CGFloat(first.height) / 2
        let label: CGFloat = 56, gap: CGFloat = 8
        let rows = Int(ceil(Double(panels.count) / Double(columns)))
        let size = CGSize(width: CGFloat(columns) * (pw + gap) + gap, height: CGFloat(rows) * (ph + label + gap) + gap)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30, weight: .heavy),
                                                        .foregroundColor: UIColor.white]
            for (i, (title, image)) in panels.enumerated() {
                let x = gap + CGFloat(i % columns) * (pw + gap)
                let y = gap + CGFloat(i / columns) * (ph + label + gap)
                (title as NSString).draw(at: CGPoint(x: x + 6, y: y + 10), withAttributes: attrs)
                UIImage(cgImage: image).draw(in: CGRect(x: x, y: y + label, width: pw, height: ph))
            }
        }
    }
}
