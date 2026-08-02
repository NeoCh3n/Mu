import SwiftUI

@main
struct MuApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(muText(store.interfaceLanguage, "New Project", "新建 Project")) {
                    store.openNewTask()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu(muText(store.interfaceLanguage, "Control Plane", "控制平面")) {
                Button(muText(store.interfaceLanguage, "Overview", "概览")) {
                    store.section = .overview
                }
                .keyboardShortcut("1", modifiers: .command)
                Button(muText(store.interfaceLanguage, "Agents", "Agents")) {
                    store.section = .agents
                }
                .keyboardShortcut("2", modifiers: .command)
                Button(muText(store.interfaceLanguage, "Projects", "Projects")) {
                    store.section = .tasks
                }
                .keyboardShortcut("3", modifiers: .command)
                Button(muText(store.interfaceLanguage, "Settings", "设置")) {
                    store.section = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button(muText(store.interfaceLanguage, "Refresh", "刷新")) {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
