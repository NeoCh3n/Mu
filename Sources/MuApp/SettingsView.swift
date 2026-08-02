import AppKit
import MuCore
import SwiftUI

struct ControlPlaneSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: muText(store.interfaceLanguage, "Settings", "设置"),
                    subtitle: muText(store.interfaceLanguage, "Configure Mu's local control plane and task notifications.", "配置 Mu 的本地控制平面和任务通知。")
                )

                Panel(
                    title: muText(store.interfaceLanguage, "Language", "语言"),
                    subtitle: muText(store.interfaceLanguage, "Choose the language used for Mu's guidance and settings.", "选择 Mu 提示和设置使用的语言。")
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(MuPalette.violet)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(muText(store.interfaceLanguage, "Interface language", "界面语言"))
                                .font(.subheadline.weight(.medium))
                            Text(muText(store.interfaceLanguage, "Only Simplified Chinese and English are available.", "目前仅支持简体中文和英文。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(
                            muText(store.interfaceLanguage, "Interface language", "界面语言"),
                            selection: Binding(
                                get: { store.interfaceLanguage },
                                set: { store.interfaceLanguage = $0 }
                            )
                        ) {
                            ForEach(MuInterfaceLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }

                Panel(
                    title: muText(store.interfaceLanguage, "Local control plane", "本地控制平面"),
                    subtitle: muText(store.interfaceLanguage, "This installation owns the state; no hosted relay is required.", "状态由本机管理，无需托管中继。")
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        settingRow(
                            symbol: "circle.fill",
                            color: MuPalette.mint,
                            title: muText(store.interfaceLanguage, "Status", "状态"),
                            value: muText(store.interfaceLanguage, "Running locally", "本机运行中")
                        )
                        Divider()
                        settingRow(
                            symbol: "externaldrive",
                            color: MuPalette.violet,
                            title: muText(store.interfaceLanguage, "SQLite database", "SQLite 数据库"),
                            value: store.service?.store.databaseURL.path ?? "Unavailable"
                        )
                        Divider()
                        settingRow(
                            symbol: "archivebox",
                            color: MuPalette.coral,
                            title: muText(store.interfaceLanguage, "Content-addressed storage", "内容寻址存储"),
                            value: store.service?.artifactStore.rootURL.path ?? "Unavailable"
                        )
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .foregroundStyle(MuPalette.violet)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(muText(store.interfaceLanguage, "Local data folder", "本地数据文件夹"))
                                    .font(.subheadline.weight(.medium))
                                Text(muText(store.interfaceLanguage, "SQLite, CAS, imported read-only history, and runtime receipts stay here.", "SQLite、CAS、导入的只读历史和运行时回执都保存在这里。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let folder = store.service?.store.databaseURL.deletingLastPathComponent() {
                                Button(muText(store.interfaceLanguage, "Reveal", "打开文件夹")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }

                Panel(
                    title: muText(store.interfaceLanguage, "Task completion notifications", "任务完成通知"),
                    subtitle: muText(store.interfaceLanguage, "Show a bottom-right confirmation after a runtime finishes a Project Task.", "运行时完成 Project 任务后，在右下角显示确认提示。")
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(
                            muText(store.interfaceLanguage, "Show task completion notifications", "显示任务完成通知"),
                            isOn: Binding(
                                get: { store.completionNotificationsEnabled },
                                set: { store.completionNotificationsEnabled = $0 }
                            )
                        )
                        .toggleStyle(.switch)

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(muText(store.interfaceLanguage, "Display time", "显示时长"))
                                    .font(.subheadline.weight(.medium))
                                Text(muText(store.interfaceLanguage, "The notification dismisses automatically after this interval. You can always close it sooner.", "通知会在此时间后自动消失，也可以提前关闭。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker(
                                muText(store.interfaceLanguage, "Display time", "显示时长"),
                                selection: Binding(
                                    get: { store.completionToastDuration },
                                    set: { store.completionToastDuration = $0 }
                                )
                            ) {
                                ForEach(AppStore.completionToastDurationOptions, id: \.self) { seconds in
                                    Text(seconds == 1 ? muText(store.interfaceLanguage, "1 second", "1 秒") : muText(store.interfaceLanguage, "\(Int(seconds)) seconds", "\(Int(seconds)) 秒"))
                                        .tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .disabled(!store.completionNotificationsEnabled)
                            .frame(width: 130)
                        }
                    }
                }

                RuntimeProviderSetupView()

                Text(muText(store.interfaceLanguage, "Mu saves these preferences locally on this Mac. Runtime records and Project state continue to save automatically.", "Mu 会将这些偏好保存在本机。运行时记录和 Project 状态会继续自动保存。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            .padding(28)
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

    private func settingRow(
        symbol: String,
        color: Color,
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
