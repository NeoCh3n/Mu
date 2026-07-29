import MuCore
import SwiftUI

struct LedgerView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""

    private var filteredEvents: [LedgerEvent] {
        guard !searchText.isEmpty else { return store.events }
        return store.events.filter {
            $0.type.localizedCaseInsensitiveContains(searchText)
                || $0.summary.localizedCaseInsensitiveContains(searchText)
                || $0.payload.values.contains(where: {
                    $0.localizedCaseInsensitiveContains(searchText)
                })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(
                    title: "Execution ledger",
                    subtitle: "Append-only canonical history. Corrections create new events."
                )
                Spacer()
                TextField("Search type, summary, or payload", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }
            .padding(26)

            Divider()

            if filteredEvents.isEmpty {
                EmptyState(
                    symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: "No matching events",
                    message: "Try another search or create a Task to append ledger history."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEvents) { event in
                            LedgerEventRow(event: event)
                            Divider().padding(.leading, 76)
                        }
                    }
                    .padding(.horizontal, 26)
                }
            }
        }
    }
}

private struct LedgerEventRow: View {
    @EnvironmentObject private var store: AppStore
    var event: LedgerEvent
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    Text("#\(event.sequence)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)

                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                        .frame(width: 28, height: 28)
                        .background(color.opacity(0.11), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(event.type)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(color)
                            if let taskID = event.taskID,
                               let task = store.task(id: taskID) {
                                Text(task.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(event.summary)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if let runID = event.runID {
                        payloadRow("run_id", runID.uuidString)
                    }
                    ForEach(event.payload.keys.sorted(), id: \.self) { key in
                        payloadRow(key, event.payload[key] ?? "")
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 74)
            }
        }
        .padding(.vertical, 13)
    }

    private func payloadRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var color: Color {
        if event.type.contains("handoff") { return MuPalette.coral }
        if event.type.contains("checkpoint") { return MuPalette.mint }
        if event.type.contains("run") || event.type.contains("replan") { return MuPalette.violet }
        return .blue
    }

    private var symbol: String {
        if event.type.contains("handoff") { return "arrow.left.arrow.right" }
        if event.type.contains("checkpoint") { return "seal" }
        if event.type.contains("replan") { return "arrow.triangle.branch" }
        if event.type.contains("run") { return "bolt" }
        if event.type.contains("task") { return "checklist" }
        return "circle.fill"
    }
}
