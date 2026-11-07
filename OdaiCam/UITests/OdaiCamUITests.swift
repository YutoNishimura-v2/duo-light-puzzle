import XCTest

/// シミュレータで、偽のカメラ（動画）を使ってひととおり遊ぶ。
/// 実機で出た不具合（カウントダウン直後に落ちる、しばりを選ぶとボタンが画面の外に出る）を渡す前に見つけるため
final class OdaiCamUITests: XCTestCase {
    /// ホームのモード列（左から順に押す。押すと中央に寄るので、隣は画面の中にある）
    /// 起動したときはしばりなし（先頭）が選ばれている
    static let modes = ["しばりなし", "棒人間", "モザイク", "着ぐるみ", "宇宙", "海", "教室", "ステージ", "影絵", "3秒遅れ", "のぞき穴", "おまかせ"]
    /// 1 ラウンド遊ぶモード。背景はどれも同じ処理なので宇宙だけ（ラウンドが増えると CI の 20 分に収まらない）
    static let roundModes: Set<String> = ["しばりなし", "宇宙", "棒人間", "着ぐるみ", "影絵", "モザイク", "3秒遅れ", "のぞき穴", "おまかせ"]
    /// 1 ラウンドの秒数（起動引数で短くする）
    // 15 秒では、CI の重いシミュレータで画面写真と配置の確認をしている間にラウンドが終わり、
    // 「パス」を押す前に結果の画面になって落ちた（run 42328558975）
    static let roundSeconds = 25
    /// シミュレータの言葉に関係なく、アプリを日本語で動かす（ボタンは日本語の名前で探すため。山札も日本語になる）
    static let japanese = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-fakeCamera", "YES", "-onboarded", "YES", "-testRoundSeconds", "\(Self.roundSeconds)",
                                 "-testFastExport", "YES"] + Self.japanese
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
        // シートの中身も中央にあるか（山札のシートが左に寄っていた）
        app.buttons["山札をえらぶ"].tap()
        let animal = app.buttons.matching(NSPredicate(format: "label CONTAINS '動物'")).firstMatch
        XCTAssertTrue(animal.waitForExistence(timeout: 5), "山札のシートが出ない")
        sleep(1)
        shot("decks")
        assertCentered(animal, name: "山札のシートの「動物」")
        app.buttons["閉じる"].tap()
        sleep(1)
        app.buttons["設定"].tap()
        let howTo = app.buttons.matching(NSPredicate(format: "label CONTAINS '遊び方'")).firstMatch
        XCTAssertTrue(howTo.waitForExistence(timeout: 5), "設定が出ない")
        sleep(1)
        shot("settings")
        assertCentered(howTo, name: "設定の「遊び方」")
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
        var first = true
        for mode in Self.modes {
            // 落ちたら、残りのラウンドは飛ばす
            guard app.state == .runningForeground else {
                XCTFail("アプリが落ちたので \(mode) から先は飛ばす")
                return
            }
            // 遊ばないモードも順に押す（押すと中央に寄るので、次のモードが画面の中に来る）
            tapMode(mode)
            sleep(1)
            guard Self.roundModes.contains(mode) else { continue }
            XCTContext.runActivity(named: "ラウンド：\(mode)") { _ in
                app.buttons["あそぶ"].tap()
                playRound(mode)
                if first {
                    // 1 回目だけ「役を交代してもう一回」も通す
                    app.buttons["役を交代してもう一回"].tap()
                    playRound("\(mode)-2回目")
                }
                app.buttons["ホームへ"].tap()
                XCTAssertTrue(app.buttons["あそぶ"].waitForExistence(timeout: 10), "\(mode)：ホームに戻れない")
                shot("\(mode)-home")
            }
            first = false
        }
    }

    /// デモモード（人形の演技と当てる人の顔を合成で流す）で 3 ラウンド遊び、種明かし動画を作る。
    /// CI はこのあとアプリの中に残った動画を取り出して、コマ画像にする。
    /// 普段のテストでは動かさない（CI の demo ジョブだけが -only-testing で呼ぶ）
    @MainActor
    func test3Demo() {
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-onboarded", "YES", "-testRoundSeconds", "30"] + Self.japanese
        app.launch()
        XCTAssertTrue(app.buttons["あそぶ"].waitForExistence(timeout: 20), "ホームが出ない")
        sleep(3)
        shot("demo-home")
        // 起動したときはしばりなし。種明かしに見えていた画面も入るよう、おまかせ（列の最後）まで順に押す
        for mode in Self.modes {
            tapMode(mode)
            sleep(1)
        }
        shot("demo-home-random")
        for round in 1...3 {
            XCTContext.runActivity(named: "デモ \(round) ラウンド目") { _ in
                if round == 1 {
                    app.buttons["あそぶ"].tap()
                } else {
                    app.buttons["役を交代してもう一回"].tap()
                }
                let correct = app.buttons["正解"]
                XCTAssertTrue(correct.waitForExistence(timeout: 45), "デモ \(round)：プレイ画面が出ない")
                // 4 秒ごとに答える（4 回に 1 回はパス）。ラウンドの終わり際（30 秒のうち最後の 8 秒ほど）は押さない
                // 押すのはプレイが始まってから 18 秒まで。シミュレータが重いと 1 回の問い合わせに数秒かかり、
                // 回数だけで区切ると終わり際に押して、同じ場所にある結果の「役を交代してもう一回」を押してしまった
                let playStart = Date()
                var n = 0
                while correct.exists && app.state == .runningForeground && n < 5 {
                    sleep(4)
                    guard correct.exists, Date().timeIntervalSince(playStart) < 18 else { break }
                    n += 1
                    if n == 2 { shot("demo-\(round)-play") }
                    // ラウンドが終わる瞬間と重なることがあるので、残っているときだけ押す
                    tapIfPresent(n % 4 == 0 ? app.buttons["パス"] : correct)
                }
                XCTAssertEqual(app.state, .runningForeground, "デモ \(round)：遊んでいる間に落ちた")
                XCTAssertTrue(app.buttons["ホームへ"].waitForExistence(timeout: 45), "デモ \(round)：結果が出ない")
                // シミュレータでは 1080x1920 の書き出しが 2 回あるので遅い。
                // アプリ側の上限（シミュレータ 200 秒）で打ち切り→作り直しまで見るので 7 分まで待つ
                let deadline = Date().addingTimeInterval(420)
                var retried = false
                while Date() < deadline {
                    if app.buttons["共有"].exists { break }
                    // 上限で打ち切られたら、画面を残して 1 回だけ「作り直す」を押す（帯なしで早く出るはず）
                    if !retried, app.buttons["作り直す"].exists {
                        shot("demo-\(round)-error")
                        tapIfPresent(app.buttons["作り直す"])
                        retried = true
                    }
                    sleep(1)
                }
                XCTAssertTrue(app.buttons["共有"].exists, "デモ \(round)：種明かし動画ができない")
                sleep(3)
                shot("demo-\(round)-results")
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
        tapIfPresent(correct)
        sleep(1)
        tapIfPresent(app.buttons["パス"])
        sleep(1)
        shot("\(name)-play-after")
        XCTAssertTrue(app.buttons["ホームへ"].waitForExistence(timeout: TimeInterval(Self.roundSeconds + 15)),
                      "\(name)：結果が出ない")
        XCTAssertEqual(app.state, .runningForeground, "\(name)：結果の前に落ちた")
        shot("\(name)-results")

        // 動画ができると「保存」「共有」が押せる。できなければ「動画を作れませんでした」
        let failed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '動画を作れませんでした'")).firstMatch
        let deadline = Date().addingTimeInterval(240)
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
        // 点数の札が画面の中にあって、字が欠けるほど細くないか
        let score = app.descendants(matching: .any)["score"]
        if score.exists {
            let screen = app.windows.firstMatch.frame
            XCTAssertTrue(screen.contains(score.frame), "\(name)：点数の札が画面の外 \(score.frame)")
            XCTAssertGreaterThanOrEqual(score.frame.width, 40, "\(name)：点数の札が細すぎる \(score.frame)")
        } else {
            XCTFail("\(name)：点数の札がない")
        }
        if failed.exists {
            // 理由の文言も残す
            let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ")
            XCTFail("\(name)：動画を作れませんでした：\(texts)")
        }
        XCTAssertTrue(ready, "\(name)：240 秒たっても動画ができない")
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

    /// ある・押せるときだけ押す（ラウンドの終わりと重なっても落ちないように）
    @MainActor
    private func tapIfPresent(_ element: XCUIElement) {
        if element.exists && element.isHittable { element.tap() }
    }

    /// ボタンの中心が、画面の中心から ±5% 以内にあるか
    @MainActor
    private func assertCentered(_ label: String, after mode: String) {
        assertCentered(app.buttons[label], name: "\(mode)：\(label)")
    }

    @MainActor
    private func assertCentered(_ element: XCUIElement, name: String) {
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(abs(element.frame.midX - screen.midX), screen.width * 0.05,
                                 "\(name) が中心からずれている \(element.frame.midX)（画面 \(screen)）")
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
