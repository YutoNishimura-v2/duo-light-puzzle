import Foundation

/// お題の山札。演じる人だけが外側の画面で見て、Duo を持つ人が当てる
struct Deck: Identifiable, Hashable {
    let id: String
    let title: String
    let prompts: [String]

    static let builtIn: [Deck] = [
        Deck(id: "animal", title: "動物", prompts: [
            "ゴリラ", "ペンギン", "カンガルー", "ゾウ", "キリン", "ヘビ", "ニワトリ", "カニ", "フラミンゴ", "ナマケモノ",
            "ハムスター", "ワニ", "コアラ", "タコ", "カエル", "ラッコ", "ライオン", "ウサギ", "クラゲ", "サル",
        ]),
        Deck(id: "job", title: "職業", prompts: [
            "消防士", "寿司職人", "美容師", "パイロット", "歯医者", "指揮者", "警察官", "マジシャン", "ボクサー", "ピアニスト",
            "カメラマン", "コック", "大工", "宇宙飛行士", "バスの運転手", "忍者", "アイドル", "相撲取り", "DJ", "お坊さん",
        ]),
        Deck(id: "sport", title: "スポーツ", prompts: [
            "サーフィン", "ボウリング", "スキー", "卓球", "弓道", "フェンシング", "重量挙げ", "ゴルフ", "バレーボール", "縄跳び",
            "スケートボード", "水泳のバタフライ", "野球のピッチャー", "カーリング", "ボルダリング", "空手", "釣り", "ダンス", "テニス", "相撲",
        ]),
        Deck(id: "action", title: "動作", prompts: [
            "歯みがき", "傘をさす", "満員電車", "ラーメンをすする", "掃除機をかける", "自撮り", "洗濯物を干す", "寝坊して走る", "くしゃみ", "風船をふくらませる",
            "ピザを伸ばす", "雪だるまを作る", "髪を乾かす", "カップ麺を待つ", "蚊をたたく", "鍵が見つからない", "重い扉を開ける", "綱引き", "花火を見る", "ネクタイを締める",
        ]),
    ]
}

/// 自分たちで作るお題帳（内輪ネタ）。1 行に 1 つ
enum CustomDeck {
    private static let key = "customPrompts"

    static var text: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var deck: Deck? {
        let prompts = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return prompts.isEmpty ? nil : Deck(id: "custom", title: "お題帳", prompts: prompts)
    }
}
