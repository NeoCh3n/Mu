import MuCore
import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var store: AppStore
    var embedded = false
    @State private var showingOtherDiscovered = false

    private var primaryEndpoints: [RuntimeEndpoint] {
        let useful = visibleRuntimeEndpoints.filter { endpoint in
            endpoint.status != .discovered
                || endpoint.instanceIdentity != nil
                || endpoint.nativeConfiguration != nil
        }
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

                Panel(title: "How Mu decides what to show", subtitle: "A simple discovery rule") {
                    VStack(alignment: .leading, spacing: 12) {
                        contractRow(
                            symbol: "magnifyingglass",
                            color: MuPalette.mint,
                            title: "Found",
                            message: "A local executable or desktop bundle exists, so Mu records a discovery."
                        )
                        contractRow(
                            symbol: "checkmark.seal",
                            color: MuPalette.violet,
                            title: "Useful",
                            message: "A stable instance identity or a successful probe makes it ready to use."
                        )
                        contractRow(
                            symbol: "arrow.triangle.2.circlepath",
                            color: MuPalette.coral,
                            title: "Duplicate",
                            message: "Unverified copies with the same runtime name are grouped; cleanup keeps the newest one."
                        )
                    }
                }
            }
            .padding(embedded ? 0 : 28)
    }

    private func contractRow(
        symbol: String,
        color: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
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
            return "Codex is available locally; check once to verify the account."
        }
        if type.contains("claude") {
            return "Claude Code was found locally; check once to verify the terminal."
        }
        if type.contains("openworker") {
            return "OpenWorker was found locally; check once to connect its desktop session."
        }
        if endpoint.provenance == .artifactOnly {
            return "Evidence-only source; it can contribute files but cannot run a Task."
        }
        return endpoint.status == .active
            ? "Verified local Runtime ready for Tasks."
            : "A Runtime candidate found on this Mac."
    }

    private var runtimeActionHint: String {
        if endpoint.status == .active {
            return "Ready for a Task. Mu will use this endpoint when you choose it."
        }
        if endpoint.status == .discovered {
            return "Found but not checked yet. Probe it before routing work."
        }
        return "Not ready for work yet. Check the Runtime or remove it."
    }

    private var friendlyStatus: String {
        switch endpoint.status {
        case .active: "Ready"
        case .discovered: "Found"
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
        case .discovered, .probing: MuPalette.coral
        case .degraded, .quarantined: .red
        case .offline: .secondary
        }
    }

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
