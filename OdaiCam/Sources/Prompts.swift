import Foundation

/// お題の山札。演じる人だけが外側の画面で見て、Duo を持つ人が当てる。
/// どの山札も 50 枚以上。声を出さずに体だけで演じられるもの
struct Deck: Identifiable, Hashable {
    let id: String
    let title: String
    let prompts: [String]
    /// お題の言葉（"ja" か "en"）。声の判定の言葉を決めるのにも使う
    let language: String

    /// language を省くと日本語（いまある山札はそのまま）
    init(id: String, title: String, prompts: [String], language: String = "ja") {
        self.id = id
        self.title = title
        self.prompts = prompts
        self.language = language
    }

    /// 端末の言葉。いちばん上の言語が日本語なら "ja"、それ以外は "en"
    static var deviceLanguage: String {
        (Locale.preferredLanguages.first ?? "ja").hasPrefix("ja") ? "ja" : "en"
    }

    /// 言葉ごとの山札（"ja" 以外はすべて英語）
    static func all(language: String) -> [Deck] {
        language == "ja" ? builtIn : englishBuiltIn
    }

    /// 端末の言葉に合わせた山札。並びの先頭は動物
    static var forDevice: [Deck] { all(language: deviceLanguage) }

    /// 端末の言葉での最初の山札（Game の初期値）
    static var defaultForDevice: Deck { forDevice[0] }

    static let builtIn: [Deck] = [
        // 最初はこれ（Game の初期値は builtIn[0]）
        Deck(id: "animal", title: "動物", prompts: [
            "ゴリラ", "ペンギン", "カンガルー", "ゾウ", "キリン", "ヘビ", "ニワトリ", "カニ", "フラミンゴ", "ナマケモノ",
            "ハムスター", "ワニ", "コアラ", "タコ", "カエル", "ラッコ", "ライオン", "ウサギ", "クラゲ", "サル",
            "パンダ", "カバ", "シマウマ", "クジャク", "カメ", "イルカ", "クマ", "ネコ", "イヌ", "ウマ",
            "ヒツジ", "ブタ", "フクロウ", "コウモリ", "カマキリ", "チーター", "ダチョウ", "アリクイ", "ハリネズミ", "カピバラ",
            "アザラシ", "オットセイ", "モグラ", "リス", "カタツムリ", "トナカイ", "ペリカン", "キツツキ", "サソリ", "イカ",
        ]),
        Deck(id: "job", title: "職業", prompts: [
            "消防士", "寿司職人", "美容師", "パイロット", "歯医者", "指揮者", "警察官", "マジシャン", "ボクサー", "ピアニスト",
            "カメラマン", "コック", "大工", "宇宙飛行士", "バスの運転手", "忍者", "アイドル", "相撲取り", "DJ", "お坊さん",
            "保育士", "看護師", "ラッパー", "ユーチューバー", "バーテンダー", "漫画家", "画家", "庭師", "引っ越し屋", "駅員",
            "警備員", "ネイリスト", "ヨガの先生", "バレリーナ", "外科医", "郵便屋さん", "宅配便の人", "漁師", "農家", "審判",
            "通訳", "占い師", "先生", "声優", "落語家", "ピエロ", "新聞記者", "モデル", "書道家", "ベビーシッター",
        ]),
        Deck(id: "sport", title: "スポーツ", prompts: [
            "サーフィン", "ボウリング", "スキー", "卓球", "弓道", "フェンシング", "重量挙げ", "ゴルフ", "バレーボール", "縄跳び",
            "スケートボード", "水泳のバタフライ", "野球のピッチャー", "カーリング", "ボルダリング", "空手", "釣り", "ダンス", "テニス", "相撲",
            "バスケ", "サッカーのPK", "ラグビー", "バドミントン", "柔道", "剣道", "短距離走", "マラソン", "走り幅跳び", "棒高跳び",
            "ハンマー投げ", "やり投げ", "鉄棒", "新体操", "トランポリン", "スノーボード", "フィギュアスケート", "スピードスケート", "ボート", "カヌー",
            "乗馬", "アーチェリー", "ビリヤード", "ダーツ", "ヨガ", "ハードル走", "ゴールキーパー", "ドッジボール", "ボクシング", "ラジオ体操",
        ]),
        Deck(id: "action", title: "動作", prompts: [
            "歯みがき", "傘をさす", "満員電車", "ラーメンをすする", "掃除機をかける", "自撮り", "洗濯物を干す", "寝坊して走る", "くしゃみ", "風船をふくらませる",
            "ピザを伸ばす", "雪だるまを作る", "髪を乾かす", "カップ麺を待つ", "蚊をたたく", "鍵が見つからない", "重い扉を開ける", "綱引き", "花火を見る", "ネクタイを締める",
            "目覚ましを止める", "二度寝", "コンタクトを入れる", "メイクする", "ガムを踏む", "フタが開かない", "信号待ち", "つり革につかまる", "傘が裏返る", "アイロンがけ",
            "卵を割る", "皿洗い", "布団を干す", "靴ひもを結ぶ", "キャッチボール", "じゃんけん", "腕相撲", "逆立ち", "あくび", "しゃっくり",
            "熱いお茶を飲む", "かき氷で頭キーン", "階段ダッシュ", "パソコンを打つ", "電話する", "写真を撮る", "料理の味見", "ゴミ出し", "シャンプー", "かくれんぼ",
        ]),
        Deck(id: "nomikai", title: "飲み会", prompts: [
            "乾杯", "とりあえず生", "ビールを注ぐ", "枝豆を食べる", "焼き鳥を串から外す", "唐揚げにレモン", "メニューを回す", "店員さんを呼ぶ", "幹事", "お会計",
            "割り勘", "終電ダッシュ", "二次会", "カラオケ", "タンバリン", "マイクを離さない", "酔っ払い", "千鳥足", "テーブルで寝る", "ハイボール",
            "日本酒", "おしぼりで顔を拭く", "お酌", "鍋奉行", "席替え", "自己紹介", "乾杯の音頭", "サラダを取り分ける", "ジョッキ", "ワイングラスを回す",
            "トイレに並ぶ", "王様ゲーム", "ゲームで負ける", "一発芸", "手拍子", "ハイタッチ", "記念写真", "締めのラーメン", "シャンパンタワー", "もんじゃを焼く",
            "お通し", "タクシーを止める", "お水を頼む", "ビールの泡", "二日酔い", "財布を出すフリ", "飲み放題", "ラストオーダー", "三本締め", "コール",
        ]),
        Deck(id: "couple", title: "カップル", prompts: [
            "手をつなぐ", "あーん", "壁ドン", "顎クイ", "お姫様抱っこ", "プロポーズ", "指輪を渡す", "ペアルック", "遠距離恋愛", "既読スルー",
            "ヤキモチ", "記念日", "サプライズ", "花束を渡す", "デートに遅刻", "待ち合わせ", "観覧車", "お化け屋敷", "映画館デート", "ポップコーン",
            "プリクラ", "ツーショット", "指でハート", "ケンカ", "仲直り", "バックハグ", "頭ポンポン", "告白", "フラれる", "一目惚れ",
            "ラブレター", "長電話", "おやすみLINE", "手料理", "膝枕", "相合傘", "腕を組む", "ウインク", "投げキッス", "マフラーをかける",
            "ドライブデート", "夜景を見る", "遊園地デート", "水族館デート", "ハグ", "別れ話", "結婚式", "ブーケトス", "新婚旅行", "同棲",
        ]),
        Deck(id: "aruaru", title: "あるある", prompts: [
            "スマホの充電切れ", "電車で寝過ごす", "傘を忘れる", "Wi-Fiが遅い", "自撮りの角度探し", "閉ボタン連打", "自動ドアが開かない", "タピオカを吸う", "レジで小銭探し", "改札で引っかかる",
            "イヤホンが絡まる", "リモコンがない", "ポテトをつまみ食い", "写真で目をつぶる", "足がつる", "名前が出てこない", "人違いで手を振る", "画面が割れる", "コンビニで迷う", "静電気でバチッ",
            "くしゃみが出ない", "アイスが溶ける", "蚊に刺される", "冷蔵庫を開けて閉める", "月曜の朝", "給料日", "ダイエット中の夜食", "ソファで寝落ち", "筋肉痛", "道を譲り合う",
            "カップ麺がのびる", "雨で髪が爆発", "前髪チェック", "靴下に穴", "ストローの袋飛ばし", "財布を忘れる", "寝ぐせ", "顔にスマホ落下", "ガチャで爆死", "推しのライブ",
            "バイトの面接", "テスト前の徹夜", "満員電車で押される", "点滅信号で走る", "宅配の不在票", "エアコンの温度争い", "アラーム5個", "映え写真", "ドリンクバー", "帰りにコンビニ",
        ]),
        Deck(id: "muri", title: "無理ゲー", prompts: [
            "ゾウを冷蔵庫に入れる", "空を飛ぶ", "月面を歩く", "無重力で歯みがき", "宇宙遊泳", "透明人間", "時間を止める", "恐竜から逃げる", "竜巻に巻き込まれる", "ジャングルで迷子",
            "サメと泳ぐ", "綱渡り", "火を吹く", "分身の術", "瞬間移動", "雷に打たれる", "巨大化する", "小人になる", "ロボットになる", "ゾンビから逃げる",
            "幽霊にとりつかれる", "ムーンウォーク", "ブレイクダンス", "スローモーション", "逆再生で歩く", "一輪車でジャグリング", "片足で寝る", "宇宙人と握手", "タコと綱引き", "クマに出会う",
            "水中で息止め", "ジェットコースター", "バンジージャンプ", "スカイダイビング", "氷の上で転ぶ", "砂漠で水を探す", "無人島でSOS", "ピラミッドを作る", "寿司になる", "洗濯機の中の服",
            "トースターのパン", "ポップコーンになる", "溶けるアイス", "風に飛ばされる", "鏡の中の自分", "操り人形", "自動販売機", "信号機", "スマホになる", "お掃除ロボット",
        ]),
        // 季節の山札（2026 年の冬）
        Deck(id: "winter", title: "冬・年末", prompts: [
            "クリスマスツリー", "サンタクロース", "トナカイのそり", "プレゼント交換", "ケーキを切る", "チキンを食べる", "大掃除", "窓ふき", "年賀状", "紅白歌合戦",
            "こたつ", "みかんをむく", "除夜の鐘", "年越しそば", "カウントダウン", "初日の出", "初詣", "おみくじ", "お年玉", "おせち",
            "お餅を伸ばす", "雪合戦", "かまくら", "スノボで転ぶ", "雪かき", "手に息をかける", "カイロを振る", "マフラーを巻く", "手袋", "イルミネーション",
            "忘年会", "ビンゴ大会", "福袋", "鏡餅", "羽子板", "コマ回し", "凧揚げ", "書き初め", "獅子舞", "鍋",
            "焼き芋", "おでん", "温泉", "凍った道で転ぶ", "寒くて震える", "ストーブ", "ゆず湯", "餅つき", "門松", "帰省ラッシュ",
        ]),
    ]

    /// 海外向けの英語の山札（18〜30 歳の英語圏向けに書いたもの。日本語の山札の直訳ではない）。
    /// 1〜3 語で、声を出さずに体で演じられるもの。商標・キャラクター名は入れない
    static let englishBuiltIn: [Deck] = [
        // 最初はこれ（日本語と同じく動物から）
        Deck(id: "en-animal", title: "Animals", prompts: [
            "Gorilla", "Penguin", "Kangaroo", "Elephant", "Giraffe", "Snake", "Chicken", "Crab", "Flamingo", "Sloth",
            "Hamster", "Crocodile", "Koala", "Octopus", "Frog", "Sea otter", "Lion", "Bunny", "Jellyfish", "Monkey",
            "Panda", "Hippo", "Zebra", "Peacock", "Turtle", "Dolphin", "Bear", "Cat", "Dog", "Horse",
            "Sheep", "Pig", "Owl", "Bat", "Cheetah", "Ostrich", "Anteater", "Hedgehog", "Seal", "Squirrel",
            "Snail", "Pelican", "Woodpecker", "Scorpion", "Shark", "Eagle", "Spider", "Bee", "Butterfly", "Goldfish",
            "Cow", "Duck", "Raccoon", "Skunk", "Camel", "Moose", "Lobster", "T-Rex", "Llama", "Platypus",
            "Worm", "Pug", "Seagull", "Possum", "Chameleon",
        ], language: "en"),
        Deck(id: "en-job", title: "Jobs", prompts: [
            "Firefighter", "Lifeguard", "Barista", "Barber", "Pilot", "Dentist", "Orchestra conductor", "Police officer", "Magician", "Boxer",
            "Pianist", "Photographer", "Chef", "Carpenter", "Astronaut", "Bus driver", "Mail carrier", "Delivery driver", "Nurse", "Surgeon",
            "Personal trainer", "Yoga teacher", "Ballet dancer", "DJ", "Rapper", "Influencer", "Painter", "Gardener", "Security guard", "Nail tech",
            "Farmer", "Fisherman", "Referee", "Fortune teller", "Teacher", "Mime", "Clown", "News anchor", "Model", "Babysitter",
            "Plumber", "Mechanic", "Construction worker", "Crossing guard", "Flight attendant", "Window washer", "Dog walker", "Lumberjack", "Cowboy", "Scientist",
            "Judge", "Tour guide", "Weather forecaster", "Air traffic controller", "Cashier", "Beekeeper", "Zookeeper", "Tattoo artist", "Paramedic", "Detective",
            "Baker", "Janitor",
        ], language: "en"),
        Deck(id: "en-sport", title: "Sports", prompts: [
            "Surfing", "Bowling", "Skiing", "Table tennis", "Archery", "Fencing", "Weightlifting", "Golf", "Volleyball", "Jump rope",
            "Skateboarding", "Butterfly stroke", "Baseball pitcher", "Curling", "Rock climbing", "Karate", "Fishing", "Tennis", "Sumo wrestling", "Basketball",
            "Penalty kick", "Rugby", "Badminton", "Judo", "Sprinting", "Marathon", "Long jump", "Pole vault", "Hammer throw", "Javelin",
            "Gymnastics", "Trampoline", "Snowboarding", "Figure skating", "Speed skating", "Rowing", "Kayaking", "Horse riding", "Billiards", "Darts",
            "Hurdles", "Goalkeeper", "Dodgeball", "Boxing", "Quarterback", "Touchdown dance", "Ice hockey", "Cricket", "Water polo", "Synchronized swimming",
            "Wrestling", "Cycling", "Scuba diving", "Pickleball", "Cheerleading", "Shot put", "Tug of war", "Paddleboarding", "Push-ups", "Lacrosse",
        ], language: "en"),
        Deck(id: "en-action", title: "Everyday Actions", prompts: [
            "Brushing teeth", "Yawning", "Taking a selfie", "Slurping noodles", "Vacuuming", "Opening an umbrella", "Hanging laundry", "Oversleeping", "Sneezing", "Inflating balloons",
            "Tossing pizza dough", "Blow-drying hair", "Swatting a mosquito", "Losing your keys", "Heavy door", "Snooze button", "Putting in contacts", "Doing makeup", "Stuck jar lid", "Ironing a shirt",
            "Cracking an egg", "Washing dishes", "Tying shoelaces", "Playing catch", "Rock paper scissors", "Arm wrestling", "Handstand", "Crowded subway", "Hiccups", "Sipping hot coffee",
            "Typing fast", "Taking out trash", "Washing hair", "Hide and seek", "Making the bed", "Mowing the lawn", "Parallel parking", "Shaving", "Flossing", "Walking the dog",
            "Grocery shopping", "Pumping gas", "Loading the dishwasher", "Folding laundry", "Changing a lightbulb", "Assembling furniture", "Flipping pancakes", "Chopping onions", "Painting nails", "Texting",
            "Jogging", "Stretching", "Climbing stairs", "Reading a book", "Watering plants", "Feeding the cat", "Taking a shower", "Carrying groceries", "Applying sunscreen", "Drive-thru",
            "Waving goodbye", "Hailing a taxi",
        ], language: "en"),
        // 13 歳以上でも大丈夫なパーティー（お酒は出さない）
        Deck(id: "en-party", title: "Party Night", prompts: [
            "Karaoke", "Air guitar", "Limbo", "Conga line", "Musical chairs", "Popping confetti", "Cutting the cake", "Blowing out candles", "Piñata", "Slow dance",
            "Dance-off", "Robot dance", "The worm", "Breakdancing", "Photo booth", "Group selfie", "Photobomb", "Scratching records", "Crowd surfing", "Mosh pit",
            "Glow sticks", "Making a toast", "Last pizza slice", "Board game night", "Video game rage", "Poker face", "Card trick", "Roasting marshmallows", "Ghost story", "Pillow fight",
            "Hitting high notes", "Mic drop", "Fist bump", "High five", "Chest bump", "Secret handshake", "Wallflower", "Awkward small talk", "Sneaking out early", "Bouncer",
            "Bathroom line", "Encore", "Costume party", "Spilled drink", "Hot potato", "Freeze dance", "Silent disco", "Disco ball", "Strobe lights", "Party crasher",
            "Noise complaint", "Cleaning up after", "Doing the splits", "Cartwheel", "Hype man", "Bongo drums",
        ], language: "en"),
        Deck(id: "en-couple", title: "Couples & Dating", prompts: [
            "Holding hands", "Proposing", "First date", "Blind date", "Sharing a milkshake", "Couple selfie", "Matching outfits", "Long distance", "Left on read", "Jealousy",
            "Anniversary", "Surprise date", "Giving flowers", "Running late", "Ferris wheel", "Haunted house", "Movie date", "Sharing popcorn", "Finger heart", "First fight",
            "Making up", "Back hug", "Head pat", "Confessing feelings", "Getting dumped", "Love at first sight", "Love letter", "Late night call", "Cooking together", "Sharing an umbrella",
            "Arm in arm", "Wink", "Blowing a kiss", "Wrapping a scarf", "Road trip", "Stargazing", "Picnic", "Wedding", "Bouquet toss", "Honeymoon",
            "Moving in together", "Meeting the parents", "Swiping right", "Double texting", "Double date", "Piggyback ride", "Kitchen dancing", "Stealing fries", "Hogging the blanket", "Picking a movie",
            "Butterflies", "Friend zone", "Third wheel", "Breakup", "Holding the door", "Beach sunset", "Ice skating date",
        ], language: "en"),
        // 「あるある」の英語版（直訳ではなく英語圏の日常）
        Deck(id: "en-relatable", title: "Relatable", prompts: [
            "Stubbed toe", "Phone at 1%", "Waiting for pickup", "Brain freeze", "Slow Wi-Fi", "Lost the remote", "Tangled earbuds", "Cracked screen", "Phone on face", "Leg cramp",
            "Forgot their name", "Waving at strangers", "Pushing pull doors", "Static shock", "Sneeze won't come", "Melting ice cream", "Mosquito bite", "Fridge staring", "Monday morning", "Payday",
            "Midnight snack", "Couch nap", "Sore muscles", "Hallway dodge", "Bad hair day", "Hole in sock", "Forgot your wallet", "Slept through alarm", "All-nighter", "Job interview nerves",
            "Packed elevator", "Chasing the bus", "Missed the bus", "Thermostat war", "Typing then deleting", "Talking while muted", "Frozen video call", "Autocorrect fail", "Taking 100 selfies", "Burnt tongue",
            "Paper cut", "Earworm", "Tripping on nothing", "Totally blanking", "Wobbly shopping cart", "Self-checkout error", "Lost your car", "Slow walkers", "Spam call", "Elevator small talk",
            "Wrong turn", "Stubborn ketchup bottle", "Folding fitted sheets", "Sunburn", "Stepping on toys", "Pretending to text", "Impossible packaging", "Gym selfie",
        ], language: "en"),
        Deck(id: "en-impossible", title: "Impossible Mode", prompts: [
            "Moon landing", "Spacewalk", "Turning invisible", "Stopping time", "Dinosaur chase", "Inside a tornado", "Jungle survival", "Swimming with sharks", "Tightrope walk", "Breathing fire",
            "Teleporting", "Struck by lightning", "Shrinking", "Becoming a robot", "Zombie apocalypse", "Ghost possession", "Slow-motion fight", "Rewinding time", "Unicycle juggling", "Meeting an alien",
            "Bear encounter", "Quicksand", "Desert mirage", "Deserted island", "Building a pyramid", "Becoming a burrito", "Being popcorn", "Melting snowman", "Blown away", "Mirror reflection",
            "Puppet on strings", "Vending machine", "Traffic light", "Robot vacuum", "Washing machine", "Lava lamp", "Toaster", "Wi-Fi signal", "Black hole", "Volcano erupting",
            "Northern lights", "Solar eclipse", "Gravity flipping", "Photosynthesis", "Caterpillar to butterfly", "Glitching video game", "Time traveler", "Superhero landing", "Moonwalk", "Jet lag",
            "Being a cloud", "Ocean wave", "Inflatable tube man", "Revolving door", "Buffering", "Ice cube melting", "Procrastination", "Deja vu",
        ], language: "en"),
        // 季節の山札（2026 年 11 月〜：感謝祭・クリスマス・年越し）
        Deck(id: "en-holiday", title: "Holiday Season", prompts: [
            "Carving the turkey", "Pumpkin pie", "Wishbone", "Food coma", "Parade float", "Giant balloon", "Backyard football", "Giving thanks", "Second helping", "Mashed potatoes",
            "Black Friday rush", "Pilgrim hat", "Leftovers", "Decorating the tree", "Santa Claus", "Reindeer sleigh", "Hanging stockings", "Wrapping presents", "Opening presents", "Ugly sweater",
            "Secret Santa", "Building a snowman", "Snowball fight", "Snow angel", "Ice skating", "Caroling", "Gingerbread house", "Hot cocoa", "Candy cane", "Untangling lights",
            "Chimney", "Elf", "Nutcracker", "Baking cookies", "Milk and cookies", "Sledding", "Shoveling snow", "Fireplace", "Advent calendar", "Regifting",
            "Fake gift smile", "Lighting a menorah", "Spinning a dreidel", "Countdown", "Fireworks", "Ball drop", "Popping champagne", "Party hat", "Party horn", "New Year's resolution",
            "January gym rush", "Scraping the windshield", "Shivering", "Mittens", "Earmuffs", "Airport delay", "Family photo", "Matching pajamas", "Kids' table", "Awkward family dinner",
        ], language: "en"),
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
        return prompts.isEmpty ? nil : Deck(id: "custom", title: Deck.deviceLanguage == "ja" ? "自分の山札" : "My Deck", prompts: prompts, language: Deck.deviceLanguage)
    }
}
