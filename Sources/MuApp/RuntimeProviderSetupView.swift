import MuCore
import SwiftUI

/// User-facing provider choices. The runtime endpoint remains the source of
/// truth; these cards keep configuration understandable without exposing
/// adapter IDs, manifests, or gateway internals.
enum MuRuntimeProvider: String, CaseIterable, Identifiable {
    case codex
    case claudeCode
    case pi
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .pi: "Pi"
        case .openCode: "OpenCode"
        }
    }

    var runtimeTypeID: String {
        switch self {
        case .codex: ControlPlaneService.codexRuntimeTypeID
        case .claudeCode: ControlPlaneService.claudeCodeRuntimeTypeID
        case .pi: "pi/coding-agent"
        case .openCode: "opencode/cli"
        }
    }

    var defaultDisplayName: String {
        switch self {
        case .codex: "Codex CLI / Desktop"
        case .claudeCode: "Claude Code CLI"
        case .pi: "Pi CLI"
        case .openCode: "OpenCode CLI"
        }
    }

    var summary: String {
        switch self {
        case .codex:
            "Configure Codex Desktop or CLI; each concrete instance remains separate."
        case .claudeCode:
            "Configure a Claude Code terminal and choose it from the Project composer."
        case .pi:
            "Choose the Pi executable once, then select Pi from the Project composer."
        case .openCode:
            "Choose the OpenCode executable once, then select it from the Project composer."
        }
    }

    var isNativeAdapterAvailable: Bool {
        self == .codex || self == .claudeCode
    }
}

struct RuntimeProviderSetupView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Panel(
            title: muText(store.interfaceLanguage, "Runtime setup", "运行时配置"),
            subtitle: muText(store.interfaceLanguage, "Configure the local LLM host here. Agent identities are optional.", "在这里配置本地 LLM host。Agent 身份不是必选项。")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MuRuntimeProvider.allCases) { provider in
                    RuntimeProviderSetupRow(
                        provider: provider,
                        endpoint: endpoint(for: provider)
                    )
                }
            }
        }
    }

    private func endpoint(for provider: MuRuntimeProvider) -> RuntimeEndpoint? {
        store.endpoints.first { endpoint in
            (endpoint.runtimeTypeID == provider.runtimeTypeID
                || endpoint.runtimeTypeID.localizedCaseInsensitiveContains(provider.rawValue)
            ) && hasRuntimeEvidence(endpoint)
        }
    }
}

private struct RuntimeProviderSetupRow: View {
    @EnvironmentObject private var store: AppStore
    let provider: MuRuntimeProvider
    let endpoint: RuntimeEndpoint?

    private var statusTitle: String {
        guard let endpoint, isConfiguredRuntime(endpoint) else {
            return muText(store.interfaceLanguage, "Not configured", "未配置")
        }
        switch endpoint.status {
        case .active: return muText(store.interfaceLanguage, "Ready", "就绪")
        case .discovered: return muText(store.interfaceLanguage, "Found · check below", "已发现 · 请在下方检查")
        default: return muText(store.interfaceLanguage, "Needs setup", "需要配置")
        }
    }

    private var statusColor: Color {
        guard let endpoint, isConfiguredRuntime(endpoint) else {
            return .secondary
        }
        return endpoint.status == .active ? MuPalette.mint : MuPalette.coral
    }

    private var detectedExecutablePath: String? {
        if let configured = endpoint?.nativeConfiguration?["executable"],
           !configured.isEmpty {
            return configured
        }
        if let configured = endpoint?.instanceIdentity?.executablePath,
           !configured.isEmpty {
            return configured
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let names: [String]
        switch provider {
        case .codex: names = ["codex"]
        case .claudeCode: names = ["claude"]
        case .pi: names = ["pi"]
        case .openCode: names = ["opencode"]
        }
        let candidates = names.flatMap { name in
            [
                "\(home)/.local/bin/\(name)",
                "\(home)/.claude/local/\(name)",
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)"
            ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map { "\($0)/\(name)" }
        }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: provider.isNativeAdapterAvailable ? "cpu" : "terminal")
                .foregroundStyle(providerColor)
                .frame(width: 24, height: 24)
                .background(providerColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(provider.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(statusTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(localizedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if endpoint?.status == .active {
                Label(muText(store.interfaceLanguage, "Configured", "已配置"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MuPalette.mint)
            } else {
                Button(muText(store.interfaceLanguage, canProbe ? "Check now" : "Configure", canProbe ? "立即检查" : "配置")) {
                    if canProbe, let endpoint {
                        switch provider {
                        case .codex: store.probeCodex(endpoint)
                        case .claudeCode: store.probeClaudeCode(endpoint)
                        case .pi, .openCode:
                            store.openRuntimeSetup(
                                provider,
                                executablePath: detectedExecutablePath
                            )
                        }
                    } else {
                        store.openRuntimeSetup(
                            provider,
                            executablePath: detectedExecutablePath
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }

    private var canProbe: Bool {
        endpoint?.status == .discovered && provider.isNativeAdapterAvailable
    }

    private var providerColor: Color {
        switch provider {
        case .codex: .blue
        case .claudeCode: MuPalette.violet
        case .pi: MuPalette.mint
        case .openCode: MuPalette.coral
        }
    }

    private var localizedSummary: String {
        if store.interfaceLanguage == .simplifiedChinese {
            switch provider {
            case .codex: return "配置 Codex Desktop 或 CLI；不同实例会分开显示。"
            case .claudeCode: return "配置 Claude Code terminal，然后在 Project 输入框中选择。"
            case .pi: return "配置一次 Pi 可执行文件，然后在 Project 输入框中选择。"
            case .openCode: return "配置一次 OpenCode 可执行文件，然后在 Project 输入框中选择。"
            }
        }
        return provider.summary
    }
}

/// A discovered record is only real enough for the setup cards when it has
/// concrete executable/identity evidence. Merely finding a command on PATH is
/// intentionally not a configured Runtime; the path is used only as a form
/// prefill when the user chooses Configure.
private func hasRuntimeEvidence(_ endpoint: RuntimeEndpoint) -> Bool {
    if endpoint.status != .discovered { return true }
    let configuration = endpoint.nativeConfiguration ?? [:]
    if ["executable", "application_path", "bundle_identifier", "terminal_id", "tty"].contains(where: { key in
        guard let value = configuration[key] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) { return true }
    if configuration.contains(where: { key, value in
        key.hasPrefix("identity.") && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) { return true }
    guard let identity = endpoint.instanceIdentity else { return false }
    if identity.identityBasis != .installation { return true }
    if identity.executablePath != nil
        || identity.terminalIdentifier != nil
        || identity.nativeSource != nil
        || identity.workspacePath != nil
        || identity.surfaceKind == .desktopApplication {
        return true
    }
    return identity.stableInstanceKey != "\(endpoint.runtimeTypeID):\(endpoint.id)"
}

private func isConfiguredRuntime(_ endpoint: RuntimeEndpoint) -> Bool {
    endpoint.status == .active
        || endpoint.nativeConfiguration?[RuntimeIdentityConfigurationKey.nativeSource]
            == "user_configured"
}
