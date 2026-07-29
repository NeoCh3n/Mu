import MuCore
import SwiftUI

enum MuPalette {
    static let violet = Color(red: 0.43, green: 0.30, blue: 0.94)
    static let coral = Color(red: 0.96, green: 0.43, blue: 0.30)
    static let mint = Color(red: 0.20, green: 0.72, blue: 0.58)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.15)
}

struct StatusPill: View {
    var label: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct TaskStatusPill: View {
    var status: TaskStatus

    var body: some View {
        StatusPill(label: status.displayName, color: color, symbol: symbol)
    }

    private var color: Color {
        switch status {
        case .draft, .ready: .secondary
        case .running: MuPalette.mint
        case .handoffPending: MuPalette.coral
        case .blocked, .failed: .red
        case .completed: .blue
        case .cancelled: .gray
        }
    }

    private var symbol: String {
        switch status {
        case .running: "bolt.fill"
        case .handoffPending: "arrow.left.arrow.right"
        case .completed: "checkmark"
        case .blocked, .failed: "exclamationmark"
        case .draft, .ready: "circle"
        case .cancelled: "xmark"
        }
    }
}

struct Panel<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        }
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var detail: String
    var color: Color
    var symbol: String

    var body: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct EndpointBadge: View {
    var endpoint: RuntimeEndpoint?
    var fallback: String = "Unknown endpoint"
    var isRemoved = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(!isRemoved && endpoint?.status == .active ? MuPalette.mint : Color.secondary)
                .frame(width: 7, height: 7)
            Text(
                endpoint.map {
                    isRemoved
                        ? "\($0.muInstanceDisplayName) · Removed"
                        : $0.muInstanceDisplayName
                } ?? fallback
            )
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct RuntimeInstanceIdentityLabel: View {
    var identity: AgentRuntimeInstanceIdentity
    var showsEvidence = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(identity.instanceLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(identity.surfaceKind.displayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.10), in: Capsule())
                    .fixedSize()
            }

            if showsEvidence {
                Text(evidenceText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(identity.instanceLabel), \(identity.surfaceKind.displayName)"
        )
        .accessibilityHint(evidenceText)
    }

    private var evidenceText: String {
        switch identity.identityBasis {
        case .desktopSingleton:
            return "One local desktop application; conversations remain separate."
        case .terminalIdentifier:
            return "Terminal identity: \(identity.terminalIdentifier ?? "recorded by the runtime")"
        case .sessionFallback:
            if identity.surfaceKind == .terminalCLI {
                return "The source did not record a terminal name; this native session ID keeps the CLI instance distinct."
            }
            return "This native session ID is the narrowest reliable instance identity."
        case .endpointFallback:
            return "This registered Runtime endpoint is the narrowest reliable instance identity."
        case .installation:
            return "This installation or configuration root identifies the source."
        case .unknown:
            return "The source did not expose a stronger instance identity."
        }
    }

    private var symbol: String {
        switch identity.surfaceKind {
        case .desktopApplication: "macwindow"
        case .terminalCLI: "terminal"
        case .editorExtension: "chevron.left.forwardslash.chevron.right"
        case .automation: "gearshape.2"
        case .localService: "server.rack"
        case .remoteService: "network"
        case .historyArtifact: "doc.text.magnifyingglass"
        case .unknown: "questionmark.square.dashed"
        }
    }

    private var color: Color {
        switch identity.surfaceKind {
        case .desktopApplication: MuPalette.violet
        case .terminalCLI: MuPalette.mint
        case .editorExtension: .blue
        case .automation: MuPalette.coral
        case .localService, .remoteService: .secondary
        case .historyArtifact, .unknown: .secondary
        }
    }
}

extension RuntimeEndpoint {
    var muInstanceDisplayName: String {
        let identity = resolvedInstanceIdentity
        switch identity.provider {
        case .codex, .claudeCode, .openWorker:
            return identity.instanceLabel
        default:
            return displayName
        }
    }

    var muRuntimePickerLabel: String {
        let instanceName = muInstanceDisplayName
        guard instanceName != displayName else {
            return "\(displayName) · \(provenance.displayName)"
        }
        return "\(instanceName) · \(displayName)"
    }
}

extension Date {
    var muRelative: String {
        formatted(.relative(presentation: .named))
    }
}

extension Color {
    init(muHex hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var integer: UInt64 = 0
        Scanner(string: value).scanHexInt64(&integer)
        let red = Double((integer >> 16) & 0xff) / 255
        let green = Double((integer >> 8) & 0xff) / 255
        let blue = Double(integer & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
