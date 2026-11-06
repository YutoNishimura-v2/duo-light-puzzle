import XCTest

/// シミュレータで、偽のカメラ（動画）を使ってひととおり遊ぶ。
/// 実機で出た不具合（カウントダウン直後に落ちる、しばりを選ぶとボタンが画面の外に出る）を渡す前に見つけるため
final class OdaiCamUITests: XCTestCase {
    /// ホームのモード列（左から順に押す。押すと中央に寄るので、隣は画面の中にある）
    static let modes = ["おまかせ", "棒人間", "影絵", "モザイク", "3秒遅れ", "のぞき穴", "しばりなし"]
    /// 1 ラウンドの秒数（起動引数で短くする）
    static let roundSeconds = 8

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-fakeCamera", "YES", "-onboarded", "YES", "-testRoundSeconds", "\(Self.roundSeconds)"]
        app.launch()
        XCTAssertTrue(app.buttons["あそぶ"].waitForExistence(timeout: 20), "ホームが出ない")
        // 偽カメラのコマが届くまで待つ
        sleep(2)
    }

    /// しばりを選ぶたびに、あそぶ・設定のボタンが画面の中で押せるか
    @MainActor
    func test1HomeModes() {
        launch()
        shot("home")
        for mode in Self.modes {
            tapMode(mode)
            // しばりの絵が届くまで待つ
            sleep(2)
            shot("home-\(mode)")
            assertOnScreen("あそぶ", after: mode)
            assertOnScreen("設定", after: mode)
            assertCentered("あそぶ", after: mode)
            XCTAssertEqual(app.state, .runningForeground, "\(mode) を選んだら落ちた")
        }
    }

    /// しばりごとに 1 ラウンド遊び、種明かしの動画ができるまで見る
    @MainActor
    func test2Rounds() {
        launch()
        // 動画の失敗はしばりごとに見たいので、1 つ失敗しても続ける
        continueAfterFailure = true
        // 時間のボタンは押すたびに 30・60・90 秒と変わる。30 秒になるまで押す
        let time = app.buttons["time"]
        XCTAssertTrue(time.waitForExistence(timeout: 5), "時間のボタンがない")
        for _ in 0..<3 where !time.label.hasPrefix("30") { time.tap() }
        XCTAssertTrue(time.label.hasPrefix("30"), "30 秒にできない：\(time.label)")
        for (i, mode) in Self.modes.enumerated() {
            // 落ちたら、残りのラウンドは飛ばす
            guard app.state == .runningForeground else {
                XCTFail("アプリが落ちたので \(mode) から先は飛ばす")
                return
            }
            tapMode(mode)
            sleep(1)
            XCTContext.runActivity(named: "ラウンド：\(mode)") { _ in
                app.buttons["あそぶ"].tap()
                playRound(mode)
                if i == 0 {
                    // 1 回目だけ「役を交代してもう一回」も通す
                    app.buttons["役を交代してもう一回"].tap()
                    playRound("\(mode)-2回目")
                }
                app.buttons["ホームへ"].tap()
                XCTAssertTrue(app.buttons["あそぶ"].waitForExistence(timeout: 10), "\(mode)：ホームに戻れない")
                shot("\(mode)-home")
            }
        }
    }

    // MARK: 下ごしらえ

    /// カウントダウン → プレイ（正解とパス）→ 結果 → 動画ができるまで
    @MainActor
    private func playRound(_ name: String) {
        sleep(1)
        shot("\(name)-countdown")
        let correct = app.buttons["正解"]
        XCTAssertTrue(correct.waitForExistence(timeout: 10), "\(name)：カウントダウンのあとプレイ画面が出ない")
        XCTAssertEqual(app.state, .runningForeground, "\(name)：カウントダウンのあと落ちた")
        sleep(1)
        shot("\(name)-play")
        // 正解とパスの組が、画面の中心から ±5% 以内にある（左に寄る不具合の見張り）
        let pass = app.buttons["パス"]
        let screen = app.windows.firstMatch.frame
        let mid = (correct.frame.midX + pass.frame.midX) / 2
        XCTAssertLessThanOrEqual(abs(mid - screen.midX), screen.width * 0.05,
                                 "\(name)：正解とパスが中心からずれている \(mid)（画面 \(screen)）")
        correct.tap()
        sleep(1)
        app.buttons["パス"].tap()
        sleep(1)
        shot("\(name)-play-after")
        XCTAssertTrue(app.buttons["ホームへ"].waitForExistence(timeout: TimeInterval(Self.roundSeconds + 15)),
                      "\(name)：結果が出ない")
        XCTAssertEqual(app.state, .runningForeground, "\(name)：結果の前に落ちた")
        shot("\(name)-results")

        // 動画ができると「保存」「共有」が押せる。できなければ「動画を作れませんでした」
        let failed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '動画を作れませんでした'")).firstMatch
        let deadline = Date().addingTimeInterval(120)
        var ready = false
        while Date() < deadline {
            if app.buttons["共有"].exists || (app.buttons["保存"].exists && app.buttons["保存"].isEnabled) { ready = true; break }
            if failed.exists { break }
            if app.state != .runningForeground {
                XCTFail("\(name)：動画を作っている間に落ちた")
                return
            }
            sleep(1)
        }
        shot("\(name)-highlight")
        if failed.exists {
            // 理由の文言も残す
            let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ")
            XCTFail("\(name)：動画を作れませんでした：\(texts)")
        }
        XCTAssertTrue(ready, "\(name)：120 秒たっても動画ができない")
    }

    @MainActor
    private func tapMode(_ mode: String) {
        let button = app.buttons[mode]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "モード \(mode) がない")
        button.tap()
    }

    /// ボタンが押せて、枠ごと画面の中にあるか
    @MainActor
    private func assertOnScreen(_ label: String, after mode: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(mode)：\(label) がない")
        XCTAssertTrue(button.isHittable, "\(mode)：\(label) が押せない")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(button.frame), "\(mode)：\(label) が画面の外 \(button.frame)（画面 \(screen)）")
    }

    /// ボタンの中心が、画面の中心から ±5% 以内にあるか
    @MainActor
    private func assertCentered(_ label: String, after mode: String) {
        let button = app.buttons[label]
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(abs(button.frame.midX - screen.midX), screen.width * 0.05,
                                 "\(mode)：\(label) が中心からずれている \(button.frame.midX)（画面 \(screen)）")
    }

    /// 画面写真を結果に残す
    @MainActor
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
