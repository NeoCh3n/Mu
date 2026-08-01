import MuCore
import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var store: AppStore
    var embedded = false
    @State private var showingOtherDiscovered = false

    private var primaryEndpoints: [RuntimeEndpoint] {
        let useful = store.endpoints.filter { endpoint in
            endpoint.status != .discovered
                || endpoint.instanceIdentity != nil
                || endpoint.nativeConfiguration != nil
        }
        return deduplicatedEndpoints(useful)
    }

    private var otherDiscoveredEndpoints: [RuntimeEndpoint] {
        let primaryIDs = Set(primaryEndpoints.map(\.id))
        return store.endpoints
            .filter { !primaryIDs.contains($0.id) }
            .sorted { $0.lastProbedAt > $1.lastProbedAt }
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
                            "\(primaryEndpoints.count) useful endpoints · "
                                + "\(otherDiscoveredEndpoints.count) other discoveries"
                    )
                    Spacer()
                    Button {
                        store.isRegisteringRuntime = true
                    } label: {
                        Label("Register runtime", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                }

                if store.endpoints.isEmpty {
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

                Panel(title: "Capability contract", subtitle: "First-slice scheduling boundary") {
                    VStack(alignment: .leading, spacing: 12) {
                        contractRow(
                            symbol: "checkmark.shield.fill",
                            color: MuPalette.mint,
                            title: "Capability-gated",
                            message: "Start and Replan must be current before Mu proposes a receiving Handoff."
                        )
                        contractRow(
                            symbol: "exclamationmark.triangle.fill",
                            color: MuPalette.coral,
                            title: "Weaker guarantees stay visible",
                            message: "Artifact-only bridges never imply live control, resume, permission interception, or quiescence."
                        )
                        contractRow(
                            symbol: "arrow.triangle.2.circlepath",
                            color: MuPalette.violet,
                            title: "Runtime change means new Run",
                            message: "A cross-runtime receiver must reconstruct a plan from the sealed Checkpoint."
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
                        Text(
                            endpoint.muInstanceDisplayName == endpoint.displayName
                                ? endpoint.runtimeTypeID
                                : "\(endpoint.displayName) · \(endpoint.runtimeTypeID)"
                        )
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    StatusPill(
                        label: endpoint.status.rawValue.capitalized,
                        color: statusColor,
                        symbol: endpoint.status == .active ? "checkmark" : nil
                    )
                    .fixedSize()
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        metadata("VERSION", endpoint.runtimeVersion)
                        metadata("PROVENANCE", endpoint.provenance.displayName)
                    }
                    GridRow {
                        metadata(
                            "SURFACE",
                            endpoint.resolvedInstanceIdentity
                                .surfaceKind.displayName
                        )
                        metadata("INSTANCE BASIS", instanceBasisLabel)
                    }
                    GridRow {
                        metadata(
                            "CONTROL",
                            gateway.controlMode.rawValue
                        )
                        metadata(
                            "TRUST",
                            gateway.trustLevel.rawValue
                        )
                    }
                    GridRow {
                        metadata(
                            "EVENTS",
                            gateway.observationFidelity.rawValue
                        )
                        metadata(
                            "CONNECTION",
                            gateway.connectionKind.rawValue
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if endpoint.capabilities.isEmpty {
                    Label("No dispatch capabilities claimed", systemImage: "lock.shield")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 28, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(
                                endpoint.capabilities.sorted(by: { $0.rawValue < $1.rawValue }),
                                id: \.self
                            ) { capability in
                                Text(capability.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.055), in: Capsule())
                            }
                        }
                    }
                    .frame(height: 28)
                    .accessibilityLabel(
                        "Capabilities: "
                            + endpoint.capabilities
                                .sorted(by: { $0.rawValue < $1.rawValue })
                                .map(\.displayName)
                                .joined(separator: ", ")
                    )
                }

                Text(endpoint.guaranteeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)

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

    private var instanceBasisLabel: String {
        let identity = endpoint.resolvedInstanceIdentity
        return switch identity.identityBasis {
        case .desktopSingleton: "One desktop"
        case .terminalIdentifier:
            identity.terminalIdentifier ?? "Terminal recorded"
        case .sessionFallback: "Native session"
        case .endpointFallback: "Runtime endpoint"
        case .installation: "Installation"
        case .unknown: "Not reported"
        }
    }

    private var gateway: RuntimeGatewayManifest {
        store.adapterRegistration(endpointID: endpoint.id)?
            .manifest
            ?? endpoint.gatewayManifest
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(value.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption.weight(.medium))
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
