import MuCore
import SwiftUI

/// The Agents surface is intentionally Runtime-first. A reusable Agent
/// identity is optional data, not a prerequisite for starting work, so this
/// page only owns local Runtime setup and the registry that backs it.
struct AgentsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    SectionHeader(
                        title: muText(store.interfaceLanguage, "Agents & Runtimes", "Agents 与运行时"),
                        subtitle: muText(
                            store.interfaceLanguage,
                            "Configure a local Runtime here, then choose it when a Project starts. Agent identities are optional.",
                            "在这里配置本地 Runtime，Project 开始时再选择。Agent 身份不是必选项。"
                        )
                    )
                    Spacer()
                    Button {
                        store.openNewTask()
                    } label: {
                        Label(muText(store.interfaceLanguage, "New project", "新建 Project"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                RuntimeProviderSetupView()

                Divider()
                    .padding(.vertical, 4)

                RuntimesView(embedded: true)
            }
            .padding(26)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.reload()
                } label: {
                    Label(muText(store.interfaceLanguage, "Refresh", "刷新"), systemImage: "arrow.clockwise")
                }
            }
        }
    }
}
