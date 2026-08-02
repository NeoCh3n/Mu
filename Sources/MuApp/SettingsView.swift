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

                Panel(
                    title: muText(store.interfaceLanguage, "Runtime instructions", "运行时指令"),
                    subtitle: muText(
                        store.interfaceLanguage,
                        "Add guidance for Codex or Claude Code. Mu appends it to the governed Context Pack for each task.",
                        "为 Codex 或 Claude Code 添加指导。Mu 会在每个任务中把它附加到受治理的 Context Pack。"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        runtimePromptEditor(
                            title: muText(store.interfaceLanguage, "Codex additional instructions", "Codex 附加指令"),
                            placeholder: muText(
                                store.interfaceLanguage,
                                "Example: Prefer a short evidence-first summary and call out uncertainty.",
                                "例如：优先给出简短的证据摘要，并明确说明不确定性。"
                            ),
                            text: Binding(
                                get: { store.codexPromptInstructions },
                                set: { store.codexPromptInstructions = $0 }
                            )
                        )

                        Divider()

                        runtimePromptEditor(
                            title: muText(store.interfaceLanguage, "Claude Code additional instructions", "Claude Code 附加指令"),
                            placeholder: muText(
                                store.interfaceLanguage,
                                "Example: Explain the files you inspect before giving the final receipt.",
                                "例如：在最终回执前，说明你检查过哪些文件。"
                            ),
                            text: Binding(
                                get: { store.claudeCodePromptInstructions },
                                set: { store.claudeCodePromptInstructions = $0 }
                            )
                        )

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(MuPalette.mint)
                            Text(muText(
                                store.interfaceLanguage,
                                "Mu's required safety rules remain fixed: read-only mode, exact workspace scope, no external network, no elevated permissions, and no private chain-of-thought output.",
                                "Mu 的安全规则保持固定：只读模式、精确工作区范围、禁止外部网络、禁止提权，以及不输出私有思维链。"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack {
                            Spacer()
                            Button(muText(store.interfaceLanguage, "Reset instructions", "恢复默认指令")) {
                                store.codexPromptInstructions = ""
                                store.claudeCodePromptInstructions = ""
                            }
                            .buttonStyle(.bordered)
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

    private func runtimePromptEditor(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.medium))
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.callout)
                    .frame(minHeight: 88, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(2)
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.1))
            }
            Text(muText(
                store.interfaceLanguage,
                "Up to 8,000 characters. This is additional guidance, not a replacement for the task or safety contract.",
                "最多 8,000 个字符。这是附加指导，不能替换任务内容或安全契约。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
