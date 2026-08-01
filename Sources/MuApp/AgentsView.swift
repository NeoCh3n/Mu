import MuCore
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingOtherIdentities = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    SectionHeader(
                        title: "Agent identities",
                        subtitle: "Choose how work is framed; bind the runtime separately."
                    )
                    Spacer()
                    Button {
                        store.openNewTask()
                    } label: {
                        Label("New project", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        store.isCreatingAgent = true
                    } label: {
                        Label("Add agent", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                }

                Panel {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "person.crop.square.badge.sparkles")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(MuPalette.violet)
                            .frame(width: 44, height: 44)
                            .background(
                                MuPalette.violet.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Identity is not runtime")
                                .font(.headline)
                            Text(
                                "Starter profiles and identities you add here are fully local and deletable. "
                                    + "Each Task still names its actual endpoint, provenance, and guarantees."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(
                            label: "\(store.visibleAgentIdentities.count) shown",
                            color: MuPalette.mint,
                            symbol: "checkmark.seal"
                        )
                        if !store.hiddenAgentIdentities.isEmpty {
                            Text(
                                "\(store.hiddenAgentIdentities.count) duplicate placeholders hidden"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }

                if store.agents.isEmpty {
                    Panel {
                        VStack(spacing: 14) {
                            EmptyState(
                                symbol: "person.crop.circle.badge.plus",
                                title: "No agent identities",
                                message: "Add a work profile before creating an assigned Task."
                            )
                            Button {
                                store.isCreatingAgent = true
                            } label: {
                                Label("Add first agent", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MuPalette.violet)
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        ForEach(store.visibleAgentIdentities) { agent in
                            AgentIdentityCard(agent: agent)
                        }
                    }

                    if !store.hiddenAgentIdentities.isEmpty {
                        DisclosureGroup(
                            isExpanded: $showingOtherIdentities
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.hiddenAgentIdentities) { agent in
                                    HStack(spacing: 10) {
                                        Image(systemName: "person.crop.circle.badge.questionmark")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(agent.displayName)
                                                .font(.subheadline.weight(.medium))
                                            Text(agent.id.uuidString.lowercased())
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        Button {
                                            store.requestDelete(agent)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("Delete \(agent.displayName)")
                                        .accessibilityLabel("Delete \(agent.displayName)")
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label(
                                "Other identities · \(store.hiddenAgentIdentities.count)",
                                systemImage: "archivebox"
                            )
                            .font(.subheadline.weight(.semibold))
                        }
                        .tint(.secondary)
                        .padding(.top, 4)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                RuntimesView(embedded: true)
            }
            .padding(26)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private struct AgentIdentityCard: View {
    @EnvironmentObject private var store: AppStore
    let agent: AgentIdentity

    private var accent: Color { Color(muHex: agent.accentHex) }
    private var activeTasks: [TaskRecord] { store.activeTasks(for: agent.id) }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 13) {
                    Text(agent.shortName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(accent, in: RoundedRectangle(cornerRadius: 13))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.displayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(agent.role.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .allowsTightening(true)
                            .help(agent.role.displayName)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 7) {
                        Button {
                            store.requestDelete(agent)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete \(agent.displayName)")
                        .accessibilityLabel("Delete \(agent.displayName)")
                        StatusPill(
                            label: agent.availability.rawValue.capitalized,
                            color: agent.availability == .available
                                ? MuPalette.mint
                                : .secondary,
                            symbol: "circle.fill"
                        )
                        .fixedSize()
                    }
                }

                Text(agent.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .help(agent.summary)

                FlowTags(tags: agent.capabilityTags, accent: accent)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PREFERRED RUNTIME")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(.tertiary)
                        EndpointBadge(endpoint: store.endpoint(id: agent.preferredEndpointID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("ACTIVE TASKS")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(.tertiary)
                        Text("\(activeTasks.count)")
                            .font(.headline.monospacedDigit())
                    }
                }

                Spacer(minLength: 0)

                if let task = activeTasks.first {
                    Button {
                        store.selectTask(task)
                        store.section = .tasks
                    } label: {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(accent)
                            Text(task.title)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption.weight(.medium))
                        .padding(10)
                        .background(
                            accent.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    store.openNewTask(agentID: agent.id)
                } label: {
                    Label("Create project for \(agent.displayName)", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 326,
                maxHeight: 326,
                alignment: .topLeading
            )
        }
    }
}

private struct FlowTags: View {
    let tags: [String]
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.10), in: Capsule())
                }
            }
        }
        .frame(height: 28)
        .accessibilityLabel("Capabilities: \(tags.joined(separator: ", "))")
    }
}
