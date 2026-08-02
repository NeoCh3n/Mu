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
            "Use Codex's local App Server. Mu keeps Desktop and CLI instances separate."
        case .claudeCode:
            "Use Claude Code's local terminal session. Mu keeps the terminal identity with the Project."
        case .pi:
            "Use the Pi CLI as a local Agent host. Choose its executable once, then select Pi below the Project chat composer."
        case .openCode:
            "Use the OpenCode CLI as a local Agent host. Choose its executable once, then select OpenCode below the Project chat composer."
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
            title: "Configure Agent runtimes",
            subtitle: "Choose a local LLM host here. Agent names are optional and are not required before a Task starts."
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
            endpoint.runtimeTypeID == provider.runtimeTypeID
                || endpoint.runtimeTypeID.localizedCaseInsensitiveContains(provider.rawValue)
        }
    }
}

private struct RuntimeProviderSetupRow: View {
    @EnvironmentObject private var store: AppStore
    let provider: MuRuntimeProvider
    let endpoint: RuntimeEndpoint?

    private var statusTitle: String {
        guard let endpoint else {
            return detectedExecutablePath == nil ? "Not configured" : "Found on this Mac"
        }
        switch endpoint.status {
        case .active: return "Ready"
        case .discovered: return "Found · check in Runtimes"
        default: return "Needs setup"
        }
    }

    private var statusColor: Color {
        guard let endpoint else {
            return detectedExecutablePath == nil ? .secondary : MuPalette.coral
        }
        return endpoint.status == .active ? MuPalette.mint : MuPalette.coral
    }

    private var detectedExecutablePath: String? {
        if let configured = endpoint?.nativeConfiguration?["executable"],
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
                Text(provider.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if endpoint?.status == .active {
                Label("Configured", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MuPalette.mint)
            } else {
                Button(endpoint == nil ? "Configure" : "Check now") {
                    if let endpoint, endpoint.status == .discovered {
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

    private var providerColor: Color {
        switch provider {
        case .codex: .blue
        case .claudeCode: MuPalette.violet
        case .pi: MuPalette.mint
        case .openCode: MuPalette.coral
        }
    }
}
