import Foundation

/// 落ちたときの手がかりを残し、次に開いたとき設定の「診断」に出す。
/// Mac につながずに原因を知るため。Objective-C の例外は中身ごと、それ以外は直前の足跡だけ残る
enum CrashLog {
    private static let defaults = UserDefaults.standard
    private static let runningKey = "crash.running"
    private static let trailKey = "crash.trail"
    private static let reportKey = "crash.report"

    nonisolated(unsafe) private static var trail: [String] = []
    private static let lock = NSLock()

    /// 起動直後に呼ぶ。前回が落ちて終わっていたら、その足跡を報告に回す
    static func start() {
        let last = defaults.stringArray(forKey: trailKey) ?? []
        if defaults.bool(forKey: runningKey), !last.isEmpty, defaults.string(forKey: reportKey) == nil {
            defaults.set(String(localized: "前回は途中で終了しました。直前の操作:") + "\n" + last.joined(separator: "\n"), forKey: reportKey)
        }
        defaults.set(true, forKey: runningKey)
        defaults.set([String](), forKey: trailKey)
        NSSetUncaughtExceptionHandler { e in
            let stack = e.callStackSymbols.prefix(25).joined(separator: "\n")
            let trail = CrashLog.lock.withLock { CrashLog.trail }
            let header = String(localized: "直前の操作:")
            UserDefaults.standard.set("\(e.name.rawValue): \(e.reason ?? "")\n\n\(header)\n\(trail.joined(separator: "\n"))\n\n\(stack)",
                                      forKey: "crash.report")
            UserDefaults.standard.synchronize()
        }
    }

    /// 足跡を残す（どこで落ちたかの目印）
    static func mark(_ event: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        let list: [String] = lock.withLock {
            trail.append("\(time) \(event)")
            if trail.count > 60 { trail.removeFirst(trail.count - 60) }
            return trail
        }
        defaults.set(list, forKey: trailKey)
        // 試験の記録（CI の app.log）でも追えるように、端末のログにも出す
        NSLog("OdaiCam足跡: %@", event)
    }

    /// 裏に回ったら、正常に終わったとみなす（iOS はふつう、裏に回ったアプリを黙って終わらせる）
    static func suspended() { defaults.set(false, forKey: runningKey) }
    static func resumed() { defaults.set(true, forKey: runningKey) }

    static var report: String? { defaults.string(forKey: reportKey) }
    static func clear() { defaults.removeObject(forKey: reportKey) }
}
