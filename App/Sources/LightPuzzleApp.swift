import LightCore
import SwiftUI

@main
struct LightPuzzleApp: App {
    @State private var input = HingeInput()
    @State private var record = PlayRecord()

    var body: some Scene {
        WindowGroup {
            StageListView(input: input, record: record)
                .hingeUpdates(into: input)
                .preferredColorScheme(.dark)
        }
    }
}

struct StageListView: View {
    let input: HingeInput
    let record: PlayRecord
    @State private var stages: [Stage] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    NavigationLink {
                        GameView(stages: stages, index: index, input: input, record: record)
                    } label: {
                        HStack {
                            Text(stage.id).monospacedDigit().foregroundStyle(.secondary)
                            Text(stage.title)
                            Spacer()
                            if record.cleared.contains(stage.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                Section {
                    Text("Duo をノート PC のように置き、上の板をゆっくり動かして鏡を傾けます。光をすべての的に当てて 0.5 秒保つとクリア。閉じる操作や速さは要りません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("光の反射")
        }
        .task {
            do {
                stages = try StageCatalog.load()
            } catch {
                loadError = "ステージを読めませんでした: \(error)"
            }
        }
    }
}
