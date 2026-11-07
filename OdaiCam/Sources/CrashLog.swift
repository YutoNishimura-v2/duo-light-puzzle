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
            // iOS がメモリ不足で落とすときの基準の量（phys_footprint）も添える
            trail.append("\(time) [\(footprintMB) MB] \(event)")
            if trail.count > 60 { trail.removeFirst(trail.count - 60) }
            return trail
        }
        defaults.set(list, forKey: trailKey)
        // 試験の記録（CI の app.log）でも追えるように、端末のログにも出す
        NSLog("OdaiCam足跡: %@", event)
    }

    /// いまアプリが使っているメモリ（MB）。iOS の判定と同じ phys_footprint
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// 裏に回ったら、正常に終わったとみなす（iOS はふつう、裏に回ったアプリを黙って終わらせる）
    static func suspended() { defaults.set(false, forKey: runningKey) }
    static func resumed() { defaults.set(true, forKey: runningKey) }

    static var report: String? { defaults.string(forKey: reportKey) }
    static func clear() { defaults.removeObject(forKey: reportKey) }
}
