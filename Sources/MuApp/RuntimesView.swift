import MuCore
import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var store: AppStore
    var embedded = false
    @State private var showingOtherDiscovered = false

    private var primaryEndpoints: [RuntimeEndpoint] {
        let useful = visibleRuntimeEndpoints.filter(hasRuntimeEvidence)
        return deduplicatedEndpoints(useful)
    }

    private var otherDiscoveredEndpoints: [RuntimeEndpoint] {
        let primaryIDs = Set(primaryEndpoints.map(\.id))
        return visibleRuntimeEndpoints
            .filter { !primaryIDs.contains($0.id) }
            .sorted { $0.lastProbedAt > $1.lastProbedAt }
    }

    private var duplicateDiscoveredEndpoints: [RuntimeEndpoint] {
        Dictionary(grouping: otherDiscoveredEndpoints, by: endpointDisplayKey)
            .values
            .flatMap { candidates in
                candidates
                    .sorted { $0.lastProbedAt > $1.lastProbedAt }
                    .dropFirst()
            }
    }

    private var visibleRuntimeEndpoints: [RuntimeEndpoint] {
        store.endpoints.filter {
            $0.provenance != .synthetic && $0.provenance != .artifactOnly
        }
    }

    private func deduplicatedEndpoints(
        _ endpoints: [RuntimeEndpoint]
    ) -> [RuntimeEndpoint] {
        var grouped: [String: [RuntimeEndpoint]] = [:]
        for endpoint in endpoints {
            grouped[endpointDisplayKey(endpoint), default: []].append(endpoint)
        }
        return grouped.values.compactMap { candidates in
            candidates.sorted { lhs, rhs in
                if lhs.status == .active, rhs.status != .active { return true }
                if rhs.status == .active, lhs.status != .active { return false }
                return lhs.lastProbedAt > rhs.lastProbedAt
            }.first
        }
        .sorted { lhs, rhs in
            lhs.muInstanceDisplayName.localizedCaseInsensitiveCompare(
                rhs.muInstanceDisplayName
            ) == .orderedAscending
        }
    }

    private func endpointDisplayKey(_ endpoint: RuntimeEndpoint) -> String {
        let identity = endpoint.resolvedInstanceIdentity
        if endpoint.instanceIdentity != nil {
            return "identity|\(identity.provider.rawValue)|\(identity.stableInstanceKey)"
        }
        if let executable = endpoint.nativeConfiguration?["executable"] {
            return "executable|\(endpoint.runtimeTypeID)|\(executable)"
        }
        // Discovered records without identity evidence are not separate
        // terminals. Collapse exact display/type copies into one useful card;
        // the originals remain available in Other discovered.
        return "unidentified|\(endpoint.runtimeTypeID)|\(endpoint.displayName)"
    }

    var body: some View {
        if embedded {
            registryContent
        } else {
            ScrollView {
                registryContent
            }
        }
    }

    @ViewBuilder
    private var registryContent: some View {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    SectionHeader(
                        title: "Runtime registry",
                        subtitle:
                            "\(primaryEndpoints.count) useful · "
                                + "\(otherDiscoveredEndpoints.count) unverified discoveries"
                    )
                    Spacer()
                    if !duplicateDiscoveredEndpoints.isEmpty {
                        Button {
                            store.removeDuplicateDiscoveredEndpoints(
                                duplicateDiscoveredEndpoints
                            )
                        } label: {
                            Label(
                                "Close \(duplicateDiscoveredEndpoints.count) duplicates",
                                systemImage: "wand.and.stars"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(MuPalette.coral)
                        .help("Keep the newest copy in each unverified discovery group.")
                    }
                    Button {
                        store.isRegisteringRuntime = true
                    } label: {
                        Label("Register runtime", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                }

                if visibleRuntimeEndpoints.isEmpty {
                    Panel {
                        EmptyState(
                            symbol: "point.3.connected.trianglepath.dotted",
                            title: "No runtime endpoints",
                            message: "Register a definition; it remains Offline until a compatible adapter probe succeeds."
                        )
                    }
                } else if primaryEndpoints.isEmpty {
                    Panel {
                        EmptyState(
                            symbol: "line.3.horizontal.decrease.circle",
                            title: "No verified runtimes",
                            message: "Unverified discoveries are kept below until a useful adapter probe succeeds."
                        )
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 360), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(primaryEndpoints) { endpoint in
                            RuntimeCard(endpoint: endpoint)
                        }
                    }
                }

                if !otherDiscoveredEndpoints.isEmpty {
                    DisclosureGroup(
                        isExpanded: $showingOtherDiscovered
                    ) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 360), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(otherDiscoveredEndpoints) { endpoint in
                                RuntimeCard(endpoint: endpoint)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        HStack(spacing: 8) {
                            Label(
                                "Other discovered runtimes",
                                systemImage: "archivebox"
                            )
                            Text("\(otherDiscoveredEndpoints.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .tint(.secondary)
                }

            }
            .padding(embedded ? 0 : 28)
    }
}

private struct RuntimeCard: View {
    @EnvironmentObject private var store: AppStore
    var endpoint: RuntimeEndpoint

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: endpoint.provenance == .artifactOnly ? "archivebox" : "cpu")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(endpoint.muInstanceDisplayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(runtimePurpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    StatusPill(
                        label: friendlyStatus,
                        color: statusColor,
                        symbol: endpoint.status == .active ? "checkmark" : nil
                    )
                    .fixedSize()
                }

                RuntimeInstanceIdentityLabel(
                    identity: endpoint.resolvedInstanceIdentity,
                    showsEvidence: false
                )

                HStack(spacing: 10) {
                    Label(
                        endpoint.configuredDefaultModel.map { "Model · \($0)" }
                            ?? "Model · Runtime default",
                        systemImage: "cpu"
                    )
                    Label(
                        "Permissions · \(endpoint.permissionModel.displayName)",
                        systemImage: "lock"
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Label(runtimeActionHint, systemImage: endpoint.status == .active ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
                Divider()

                HStack(spacing: 8) {
                    if isProbeable {
                        Button {
                            probe()
                        } label: {
                            if store.probingEndpointIDs.contains(endpoint.id) {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Probing…")
                                }
                            } else {
                                Label(
                                    endpoint.status == .active ? "Re-probe" : "Probe",
                                    systemImage: "wave.3.right"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.probingEndpointIDs.contains(endpoint.id))
                        .accessibilityLabel(
                            "\(endpoint.status == .active ? "Re-probe" : "Probe") "
                                + endpoint.muInstanceDisplayName
                        )
                    } else {
                        Label("Manual endpoint", systemImage: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if endpoint.runtimeTypeID == ControlPlaneService.openWorkerRuntimeTypeID {
                        Button {
                            store.openRuntimeApplication(endpoint)
                        } label: {
                            Label("Open app", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(
                            "Open \(endpoint.muInstanceDisplayName) application"
                        )
                    }

                    Button {
                        store.openRuntimeSettings(endpoint)
                    } label: {
                        Label("Configure", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(
                        "Configure \(endpoint.muInstanceDisplayName) model and permissions"
                    )

                    Spacer(minLength: 8)

                    Button(role: .destructive) {
                        store.requestDelete(endpoint)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(
                        "Remove \(endpoint.muInstanceDisplayName) from the registry"
                    )
                    .accessibilityLabel(
                        "Remove \(endpoint.muInstanceDisplayName) from the registry"
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 352,
                maxHeight: 352,
                alignment: .topLeading
            )
        }
        .accessibilityLabel(
            "\(endpoint.muInstanceDisplayName), \(endpoint.status.rawValue.capitalized) runtime"
        )
    }

    private var runtimePurpose: String {
        let type = endpoint.runtimeTypeID.lowercased()
        if type.contains("codex") {
            return "Configure Codex and check it before starting a Task."
        }
        if type.contains("claude") {
            return "Configure a Claude Code terminal and check it before starting a Task."
        }
        if type.contains("openworker") {
            return "Native compatibility runtime; configure it before starting a Task."
        }
        if endpoint.provenance == .artifactOnly {
            return "Evidence-only source; it can contribute files but cannot run a Task."
        }
        return endpoint.status == .active
            ? "Verified local Runtime ready for Tasks."
            : "A Runtime candidate needs setup before it can run a Task."
    }

    private var runtimeActionHint: String {
        if endpoint.status == .active {
            return "Ready for a Task. Mu will use this endpoint when you choose it."
        }
        if endpoint.status == .discovered {
            return hasRuntimeEvidence(endpoint)
                ? "Found but not checked yet. Probe it before routing work."
                : "No concrete evidence is recorded yet. Configure or remove this record."
        }
        return "Not ready for work yet. Check the Runtime or remove it."
    }

    private var friendlyStatus: String {
        switch endpoint.status {
        case .active: "Ready"
        case .discovered: hasRuntimeEvidence(endpoint) ? "Found" : "Unverified"
        case .probing: "Checking"
        case .offline, .degraded, .quarantined: "Needs setup"
        }
    }

    private var isProbeable: Bool {
        endpoint.runtimeTypeID == ControlPlaneService.codexRuntimeTypeID
            || endpoint.runtimeTypeID
                == ControlPlaneService.claudeCodeRuntimeTypeID
            || endpoint.runtimeTypeID == ControlPlaneService.openWorkerRuntimeTypeID
    }

    private func probe() {
        if endpoint.runtimeTypeID == ControlPlaneService.codexRuntimeTypeID {
            store.probeCodex(endpoint)
        } else if endpoint.runtimeTypeID
                    == ControlPlaneService.claudeCodeRuntimeTypeID {
            store.probeClaudeCode(endpoint)
        } else if endpoint.runtimeTypeID == ControlPlaneService.openWorkerRuntimeTypeID {
            store.probeOpenWorker(endpoint)
        }
    }

    private var accent: Color {
        if endpoint.runtimeTypeID == ControlPlaneService.codexRuntimeTypeID {
            return .blue
        }
        if endpoint.runtimeTypeID
            == ControlPlaneService.claudeCodeRuntimeTypeID {
            return MuPalette.violet
        }
        if endpoint.runtimeTypeID == ControlPlaneService.openWorkerRuntimeTypeID {
            return MuPalette.mint
        }
        return endpoint.provenance == .artifactOnly ? MuPalette.coral : MuPalette.violet
    }

    private var statusColor: Color {
        switch endpoint.status {
        case .active: MuPalette.mint
        case .discovered: hasRuntimeEvidence(endpoint) ? MuPalette.coral : .secondary
        case .probing: MuPalette.coral
        case .degraded, .quarantined: .red
        case .offline: .secondary
        }
    }

}

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

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), points)
    }
}
