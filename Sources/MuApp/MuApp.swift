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
                Button("New Project") {
                    store.openNewTask()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Control Plane") {
                Button("Overview") {
                    store.section = .overview
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Agents") {
                    store.section = .agents
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Projects") {
                    store.section = .tasks
                }
                .keyboardShortcut("3", modifiers: .command)
                Button("Handoffs") {
                    store.section = .handoffs
                }
                .keyboardShortcut("4", modifiers: .command)
                Button("Runtimes") {
                    store.section = .runtimes
                }
                .keyboardShortcut("5", modifiers: .command)
                Button("Ledger") {
                    store.section = .ledger
                }
                .keyboardShortcut("6", modifiers: .command)
                Divider()
                Button("Refresh") {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
