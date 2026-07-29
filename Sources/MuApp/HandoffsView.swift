import MuCore
import SwiftUI

struct HandoffsView: View {
    @EnvironmentObject private var store: AppStore

    private var history: [HandoffRecord] {
        store.handoffs.filter { $0.status != .proposed && $0.status != .validating }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(
                    title: "Handoffs",
                    subtitle: "Move Task responsibility from one runtime to another using a sealed checkpoint."
                )

                handoffGuide

                if store.pendingHandoffs.isEmpty {
                    Panel {
                        HStack(alignment: .center, spacing: 14) {
                            Image(systemName: "tray")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 42, height: 42)
                                .background(
                                    Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 11)
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No handoff requests")
                                    .font(.headline)
                                Text(
                                    "Start in an active Task and capture a checkpoint. "
                                        + "That checkpoint becomes the reviewable handoff package."
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.section = .tasks
                            } label: {
                                Label("Open Projects", systemImage: "arrow.right")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MuPalette.violet)
                            .accessibilityHint("Go to Projects to capture a checkpoint")
                        }
                    }
                } else {
                    SectionHeader(
                        title: "Receiver inbox",
                        subtitle: "\(store.pendingHandoffs.count) request\(store.pendingHandoffs.count == 1 ? "" : "s") waiting for review."
                    )
                    VStack(spacing: 14) {
                        ForEach(store.pendingHandoffs) { handoff in
                            PendingHandoffCard(handoff: handoff)
                        }
                    }
                }

                if !history.isEmpty {
                    SectionHeader(
                        title: "Resolved",
                        subtitle: "Accepted and rejected responsibility transfers."
                    )
                    Panel {
                        VStack(spacing: 0) {
                            ForEach(history) { handoff in
                                HandoffHistoryRow(handoff: handoff)
                                if handoff.id != history.last?.id {
                                    Divider().padding(.leading, 42)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var handoffGuide: some View {
        Panel(
            title: "What is a Handoff?",
            subtitle: "A Handoff transfers Task ownership—not chat history. The source remains responsible until the receiver accepts."
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    guideStep(
                        number: 1,
                        symbol: "seal",
                        title: "Capture",
                        message: "Open a Task and capture its current objective, work, and Git evidence."
                    )
                    guideArrow
                    guideStep(
                        number: 2,
                        symbol: "paperplane",
                        title: "Propose",
                        message: "Choose Handoff on the checkpoint and select a compatible runtime."
                    )
                    guideArrow
                    guideStep(
                        number: 3,
                        symbol: "checkmark.shield",
                        title: "Accept & replan",
                        message: "The receiver validates the package, accepts ownership, and creates a new Run."
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    guideStep(
                        number: 1,
                        symbol: "seal",
                        title: "Capture",
                        message: "Open a Task and capture its current objective, work, and Git evidence."
                    )
                    guideStep(
                        number: 2,
                        symbol: "paperplane",
                        title: "Propose",
                        message: "Choose Handoff on the checkpoint and select a compatible runtime."
                    )
                    guideStep(
                        number: 3,
                        symbol: "checkmark.shield",
                        title: "Accept & replan",
                        message: "The receiver validates the package, accepts ownership, and creates a new Run."
                    )
                }
            }

            Divider()
            HStack {
                Label("Start from Task → Capture checkpoint", systemImage: "location.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MuPalette.violet)
                Spacer()
                Button {
                    store.section = .tasks
                } label: {
                    Label("Go to Projects", systemImage: "arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Open the Project list")
            }
        }
    }

    private func guideStep(
        number: Int,
        symbol: String,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(MuPalette.violet.opacity(0.10))
                Image(systemName: symbol)
                    .foregroundStyle(MuPalette.violet)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(title)")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title). \(message)")
    }

    private var guideArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 10)
            .accessibilityHidden(true)
    }
}

private struct PendingHandoffCard: View {
    @EnvironmentObject private var store: AppStore
    var handoff: HandoffRecord

    private var task: TaskRecord? { store.task(id: handoff.taskID) }
    private var checkpoint: CheckpointRecord? { store.checkpoint(id: handoff.checkpointID) }
    private var source: RuntimeEndpoint? { store.endpoint(id: handoff.sourceEndpointID) }
    private var receiver: RuntimeEndpoint? { store.endpoint(id: handoff.receiverEndpointID) }
    private var receiverIsRegistered: Bool {
        store.isEndpointRegistered(id: handoff.receiverEndpointID)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        StatusPill(label: "Receiver action required", color: MuPalette.coral, symbol: "bell.fill")
                        Text(task?.title ?? "Unknown Task")
                            .font(.title3.weight(.semibold))
                        Text(task?.objective ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(handoff.createdAt.muRelative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    endpointNode(
                        source,
                        fallback: store.endpointDisplayName(
                            id: handoff.sourceEndpointID,
                            fallback: "Unknown runtime"
                        ),
                        role: "SENDER",
                        color: MuPalette.violet,
                        isRemoved: store.isEndpointRemoved(id: handoff.sourceEndpointID)
                    )
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(MuPalette.coral)
                        Text("HANDOFF")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 72)
                    endpointNode(
                        receiver,
                        fallback: store.endpointDisplayName(
                            id: handoff.receiverEndpointID,
                            fallback: "Unknown runtime"
                        ),
                        role: "RECEIVER",
                        color: MuPalette.coral,
                        isRemoved: store.isEndpointRemoved(id: handoff.receiverEndpointID)
                    )
                }

                HStack(spacing: 18) {
                    fact("Checkpoint", checkpoint.map { String($0.contentHash.prefix(20)) + "…" } ?? "Missing")
                    fact("HEAD", checkpoint.map { String($0.content.repository.headCommit.prefix(10)) } ?? "—")
                    fact("Semantic", "Replan")
                    fact("Capture", "Non-exclusive")
                }

                HStack {
                    Label(
                        receiverIsRegistered
                            ? handoff.validationMessage
                            : "Receiver was removed from the registry; Accept is unavailable.",
                        systemImage: receiverIsRegistered
                            ? "checkmark.shield"
                            : "exclamationmark.triangle"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open source Task") {
                        store.selectTask(id: handoff.taskID)
                        store.section = .tasks
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Review the checkpoint and Task details")
                    Button("Reject") {
                        store.handoffToReject = handoff
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Reject handoff for \(task?.title ?? "this Task")")
                    Button("Accept & create Replan") {
                        store.acceptHandoff(handoff)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                    .disabled(!receiverIsRegistered)
                    .accessibilityLabel(
                        "Accept handoff and create replan for \(task?.title ?? "this Task")"
                    )
                }
            }
        }
    }

    private func endpointNode(
        _ endpoint: RuntimeEndpoint?,
        fallback: String,
        role: String,
        color: Color,
        isRemoved: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(isRemoved ? Color.secondary : color)
                .frame(width: 38, height: 38)
                .background(
                    (isRemoved ? Color.secondary : color).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(role)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                Text(fallback)
                    .font(.subheadline.weight(.semibold))
                Text(endpoint?.runtimeTypeID ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(13)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospaced().weight(.medium))
                .lineLimit(1)
        }
    }
}

private struct HandoffHistoryRow: View {
    @EnvironmentObject private var store: AppStore
    var handoff: HandoffRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: handoff.status == .accepted ? "checkmark" : "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(handoff.status == .accepted ? MuPalette.mint : Color.red)
                .frame(width: 30, height: 30)
                .background(
                    (handoff.status == .accepted ? MuPalette.mint : Color.red).opacity(0.10),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(store.task(id: handoff.taskID)?.title ?? "Unknown Task")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "\(store.endpointDisplayName(id: handoff.sourceEndpointID, fallback: "Unknown runtime")) → "
                    + store.endpointDisplayName(
                        id: handoff.receiverEndpointID,
                        fallback: "Unknown runtime"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                label: handoff.status.rawValue.capitalized,
                color: handoff.status == .accepted ? MuPalette.mint : .red
            )
            Text((handoff.resolvedAt ?? handoff.createdAt).muRelative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 11)
    }
}
