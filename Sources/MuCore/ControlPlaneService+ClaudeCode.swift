import Foundation

extension ControlPlaneService {
    @discardableResult
    public func dispatchClaudeCodeTask(
        runID: UUID,
        workspaceEntryID: UUID? = nil
    ) throws -> ClaudeCodeTurnResult {
        guard var run = try store.fetchRun(id: runID),
              var task = try store.fetchTask(id: run.taskID)
        else {
            throw MuError.recordNotFound(
                "Claude Code execution Run \(runID)"
            )
        }
        var workspaceEntry = try workspaceEntryID.flatMap {
            try store.fetchChatEntry(id: $0)
        }
        if let workspaceEntry {
            guard workspaceEntry.taskID == task.id,
                  workspaceEntry.targetEndpointID == run.endpointID,
                  workspaceEntry.runID == run.id,
                  workspaceEntry.runtimeSessionBindingID == nil,
                  workspaceEntry.deliveryState == .awaitingSession else {
                throw MuError.invalidTransition(
                    "The Claude Code Workspace message is not waiting for its initial session."
                )
            }
        }
        guard run.purpose == .execution else {
            throw MuError.invalidTransition(
                "Only an execution Run can start a Claude Code Task."
            )
        }
        guard run.state == .starting
                || run.state == .created else {
            throw MuError.invalidTransition(
                "This Claude Code Run is not safely dispatchable."
            )
        }
        guard task.currentRunID == run.id,
              task.currentEndpointID == run.endpointID else {
            throw MuError.invalidTransition(
                "The Claude Code Run is not the Task's current Run."
            )
        }
        guard var endpoint = try store.fetchRegisteredEndpoint(
            id: run.endpointID
        ), endpoint.runtimeTypeID
            == Self.claudeCodeRuntimeTypeID else {
            throw MuError.recordNotFound(
                "Active Claude Code CLI endpoint"
            )
        }
        try RuntimeGatewayRegistry.require(
            .createSession,
            endpoint: endpoint
        )
        guard let executablePath =
            endpoint.nativeConfiguration?["executable"] else {
            throw MuError.commandFailed(
                "Claude Code executable path is not registered."
            )
        }

        let kernel = try projectKernelContext(
            taskID: task.id
        )
        guard let actorID = kernel.actor?.id else {
            throw MuError.invalidTransition(
                "Claude Code has no authorized Project Actor."
            )
        }
        let bindingID = UUID()
        let lease = try claimTaskLease(
            taskID: task.id,
            endpointID: endpoint.id,
            actorID: actorID,
            runtimeBindingID: bindingID,
            duration: 30 * 60
        )
        let contextPack = try buildGovernedContextPack(
            taskID: task.id,
            actorID: actorID,
            endpointID: endpoint.id,
            runtimeBindingID: bindingID,
            taskLeaseID: lease.id
        )
        let initialPrompt = contextPack.renderedMarkdown
            + (workspaceEntry.map {
                "\n\n# Current Project message\n\n"
                    + ($0.routedText ?? $0.text)
            } ?? "")
        let sessionID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        var binding = RuntimeSessionBinding(
            id: bindingID,
            taskID: task.id,
            projectID: kernel.project.id,
            workspaceID: kernel.workspace.id,
            actorID: actorID,
            principalID: kernel.principal?.id,
            taskLeaseID: lease.id,
            runID: run.id,
            contextPackID: contextPack.id,
            endpointID: endpoint.id,
            agentIdentityID: run.agentIdentityID,
            nativeSessionID: sessionID,
            nativeAgentName: "Claude Code",
            workspacePath: kernel.workspace.repositoryPath,
            connectionMode: "managed_cli_stream_json",
            origin: "created_by_mu",
            state: .connecting,
            lastActivitySummary:
                "Launching a bounded Claude Code CLI session."
        )
        let responseEntry = ChatEntry(
            taskID: task.id,
            agentIdentityID: run.agentIdentityID,
            runID: run.id,
            runtimeSessionBindingID: binding.id,
            deliveryState: .routing,
            authorKind: .agent,
            authorName: "Claude Code",
            text: "Starting Claude Code…"
        )
        if var entry = workspaceEntry {
            entry.runtimeSessionBindingID = bindingID
            entry.nativeMessageIndexLowerBound = binding.lastSyncedMessageCount
            entry.deliveryState = .sending
            entry.updatedAt = Date()
            workspaceEntry = entry
        }
        let persistentRunID = run.id
        let persistentBindingID = binding.id
        run.projectID = kernel.project.id
        run.workspaceID = kernel.workspace.id
        run.actorID = actorID
        run.principalID = kernel.principal?.id
        run.taskLeaseID = lease.id
        run.contextPackID = contextPack.id
        run.nativeThreadID = sessionID
        run.nativeTurnID = turnID
        run.state = .starting
        run.updatedAt = Date()
        task.projectID = kernel.project.id
        task.workspaceID = kernel.workspace.id
        task.assignedActorID = actorID
        task.status = .running
        task.updatedAt = Date()

        do {
            try store.withTransaction {
                try store.upsertRun(run)
                try store.upsertTask(task)
                try store.upsertRuntimeSessionBinding(binding)
                if let workspaceEntry {
                    try store.upsertChatEntry(workspaceEntry)
                }
                try store.insertChatEntry(responseEntry)
                try store.appendEvent(
                    LedgerEvent(
                        projectID: kernel.project.id,
                        actorID: kernel.actor?.id,
                        principalID: kernel.principal?.id,
                        workspaceID: kernel.workspace.id,
                        taskID: task.id,
                        runID: run.id,
                        type: "claude.session.prepared",
                        summary:
                            "Prepared a native Claude Code CLI session.",
                        payload: [
                            "native_session_id": sessionID,
                            "mu_turn_id": turnID,
                            "binding_id":
                                binding.id.uuidString,
                            "lease_id": lease.id.uuidString,
                            "context_pack_id":
                                contextPack.id.uuidString
                        ]
                    )
                )
            }
        } catch {
            _ = try? releaseTaskLease(id: lease.id)
            throw error
        }

        let client = ClaudeCodeClient(
            executableURL: URL(
                fileURLWithPath: executablePath
            )
        )
        claudeRuntimeLock.withLock {
            activeClaudeClients[run.id] = client
        }
        defer {
            _ = claudeRuntimeLock.withLock {
                activeClaudeClients.removeValue(
                    forKey: persistentRunID
                )
            }
        }
        let mirror = ClaudeCodeOutputMirror {
            [weak self] text, force in
            guard let self else { return }
            try? self.persistClaudeCodeVisibleText(
                entryID: responseEntry.id,
                bindingID: persistentBindingID,
                text: text,
                force: force,
                runtimeName: "Claude Code"
            )
        }
        let activityTaskID = task.id

        do {
            try recordContextDelivery(
                projectID: kernel.project.id,
                packID: contextPack.id,
                status: .prepared
            )
            let result = try client.runReadOnlyTask(
                task: task,
                contextPack: contextPack,
                sessionID: sessionID,
                promptOverride: initialPrompt,
                onSessionStarted: {
                    [weak self] nativeSessionID in
                    guard let self else { return }
                    guard nativeSessionID == sessionID else {
                        throw MuError.invalidTransition(
                            "Claude Code acknowledged a conflicting native session."
                        )
                    }
                    try self.markClaudeCodeSessionStarted(
                        runID: persistentRunID,
                        bindingID: persistentBindingID,
                        sessionID: nativeSessionID,
                        turnID: turnID
                    )
                },
                onVisibleText: { text in
                    mirror.offer(text)
                },
                onActivity: { [weak self] activity in
                    guard let self else { return }
                    try? self.persistRuntimeActivity(
                        activity,
                        taskID: activityTaskID,
                        runID: persistentRunID,
                        projectID: kernel.project.id,
                        workspaceID: kernel.workspace.id,
                        bindingID: persistentBindingID
                    )
                }
            )
            try recordContextDelivery(
                projectID: kernel.project.id,
                packID: contextPack.id,
                status: .delivered,
                adapterReceiptMaterial:
                    "claude-code|\(result.sessionID)|\(turnID)|\(result.status)"
            )
            mirror.finish(result.output)
            run = try store.fetchRun(id: run.id) ?? run
            task = try store.fetchTask(id: task.id) ?? task
            binding =
                try store.fetchRuntimeSessionBinding(
                    id: binding.id
                ) ?? binding
            run.nativeThreadID = result.sessionID
            run.nativeTurnID = turnID
            run.nativeOutput = result.output
            run.state = result.status == "cancelled"
                ? .cancelled
                : .completed
            run.updatedAt = Date()
            task.status = result.status == "cancelled"
                ? .cancelled
                : .completed
            task.updatedAt = Date()
            binding.nativeSessionID = result.sessionID
            binding.model = result.model
            binding.state = result.status == "cancelled"
                ? .disconnected
                : .completed
            binding.lastActivitySummary =
                result.status == "cancelled"
                ? "Claude Code was interrupted in Mu."
                : "Claude Code completed the native turn."
            binding.lastError = result.errorMessage
            binding.updatedAt = Date()
            var finalEntry =
                try store.fetchChatEntry(id: responseEntry.id)
                ?? responseEntry
            finalEntry.text = result.output
            finalEntry.deliveryState = result.status == "cancelled"
                ? .cancelled
                : .mirrored
            finalEntry.updatedAt = Date()
            var finalWorkspaceEntry: ChatEntry?
            if var workspaceEntry = workspaceEntryID.flatMap({
                try? store.fetchChatEntry(id: $0)
            }) ?? workspaceEntry {
                workspaceEntry.runtimeSessionBindingID = binding.id
                workspaceEntry.deliveryState = result.status == "cancelled"
                    ? .cancelled
                    : .delivered
                workspaceEntry.updatedAt = Date()
                finalWorkspaceEntry = workspaceEntry
            }
            let artifact = try submitRuntimeOutputArtifact(
                taskID: task.id,
                producerActorID: kernel.actor?.id,
                title: "Claude Code result · \(task.title)",
                output: result.output,
                metadata: [
                    "provider":
                        ConversationProvider.claudeCode.rawValue,
                    "native_session_id": result.sessionID,
                    "mu_turn_id": turnID,
                    "model": result.model ?? "",
                    "cost_usd": result.costUSD.map {
                        String($0)
                    }
                        ?? "",
                    "duration_ms":
                        result.durationMilliseconds.map {
                            String($0)
                        }
                        ?? ""
                ]
            )
            try store.withTransaction {
                try store.upsertRun(run)
                try store.upsertTask(task)
                try store.upsertRuntimeSessionBinding(binding)
                if let workspaceEntry = finalWorkspaceEntry {
                    try store.upsertChatEntry(workspaceEntry)
                }
                try store.upsertChatEntry(finalEntry)
                try store.appendEvent(
                    LedgerEvent(
                        projectID: kernel.project.id,
                        actorID: kernel.actor?.id,
                        principalID: kernel.principal?.id,
                        workspaceID: kernel.workspace.id,
                        artifactID: artifact.id,
                        taskID: task.id,
                        runID: run.id,
                        type: result.status == "cancelled"
                            ? "claude.turn.cancelled"
                            : "claude.turn.completed",
                        summary:
                            result.status == "cancelled"
                            ? "Claude Code turn was interrupted."
                            : "Claude Code published a reviewable Runtime result.",
                        payload: [
                            "native_session_id":
                                result.sessionID,
                            "mu_turn_id": turnID,
                            "artifact_id":
                                artifact.id.uuidString,
                            "model": result.model ?? "",
                            "status": result.status
                        ]
                    )
                )
            }
            _ = try? releaseTaskLease(id: lease.id)
            endpoint.lastProbedAt = max(
                endpoint.lastProbedAt,
                Date()
            )
            return result
        } catch {
            run = try store.fetchRun(id: run.id) ?? run
            task = try store.fetchTask(id: task.id) ?? task
            binding =
                try store.fetchRuntimeSessionBinding(
                    id: binding.id
                ) ?? binding
            run.state = .failed
            run.updatedAt = Date()
            task.status = .failed
            task.updatedAt = Date()
            binding.state = .failed
            binding.lastError = error.localizedDescription
            binding.lastActivitySummary =
                "Claude Code could not complete the native turn."
            binding.updatedAt = Date()
            var failedEntry =
                try store.fetchChatEntry(id: responseEntry.id)
                ?? responseEntry
            failedEntry.text =
                "Claude Code failed: \(error.localizedDescription)"
            failedEntry.deliveryState = .failed
            failedEntry.updatedAt = Date()
            var failedWorkspaceEntry: ChatEntry?
            if var workspaceEntry = workspaceEntryID.flatMap({
                try? store.fetchChatEntry(id: $0)
            }) ?? workspaceEntry {
                workspaceEntry.runtimeSessionBindingID = binding.id
                workspaceEntry.deliveryState = .failed
                workspaceEntry.updatedAt = Date()
                failedWorkspaceEntry = workspaceEntry
            }
            try? store.withTransaction {
                try store.upsertRun(run)
                try store.upsertTask(task)
                try store.upsertRuntimeSessionBinding(binding)
                if let workspaceEntry = failedWorkspaceEntry {
                    try store.upsertChatEntry(workspaceEntry)
                }
                try store.upsertChatEntry(failedEntry)
                try store.appendEvent(
                    LedgerEvent(
                        projectID: kernel.project.id,
                        actorID: kernel.actor?.id,
                        principalID: kernel.principal?.id,
                        workspaceID: kernel.workspace.id,
                        taskID: task.id,
                        runID: run.id,
                        type: "claude.turn.failed",
                        summary:
                            "Claude Code could not complete the native turn.",
                        payload: [
                            "native_session_id": sessionID,
                            "mu_turn_id": turnID,
                            "error":
                                error.localizedDescription,
                            "automatic_retry": "disabled"
                        ]
                    )
                )
            }
            _ = try? recordContextDelivery(
                projectID: kernel.project.id,
                packID: contextPack.id,
                status: .failed,
                failureCode: "claude_runtime_dispatch_failed"
            )
            _ = try? releaseTaskLease(
                id: lease.id,
                state: .released
            )
            throw error
        }
    }

    public func interruptClaudeCodeRun(
        runID: UUID
    ) throws {
        guard let run = try store.fetchRun(id: runID),
              let endpoint = try store.fetchRegisteredEndpoint(
                  id: run.endpointID
              ),
              endpoint.runtimeTypeID
                == Self.claudeCodeRuntimeTypeID else {
            throw MuError.recordNotFound(
                "Active Claude Code Run \(runID)"
            )
        }
        try RuntimeGatewayRegistry.require(
            .interrupt,
            endpoint: endpoint
        )
        guard let client = claudeRuntimeLock.withLock({
            activeClaudeClients[runID]
        }) else {
            throw MuError.invalidTransition(
                "Claude Code is not currently running in Mu."
            )
        }
        client.interrupt()
        try store.appendEvent(
            LedgerEvent(
                projectID: run.projectID,
                actorID: run.actorID,
                principalID: run.principalID,
                workspaceID: run.workspaceID,
                taskID: run.taskID,
                runID: run.id,
                type: "claude.turn.interrupt_requested",
                summary:
                    "Requested interruption of the Mu-launched Claude Code process.",
                payload: [
                    "native_session_id":
                        run.nativeThreadID ?? "",
                    "mu_turn_id":
                        run.nativeTurnID ?? ""
                ]
            )
        )
    }

    private func markClaudeCodeSessionStarted(
        runID: UUID,
        bindingID: UUID,
        sessionID: String,
        turnID: String
    ) throws {
        guard var run = try store.fetchRun(id: runID),
              var binding =
                try store.fetchRuntimeSessionBinding(
                    id: bindingID
                ) else {
            throw MuError.recordNotFound(
                "Claude Code session receipt"
            )
        }
        guard run.nativeThreadID == sessionID,
              binding.nativeSessionID == sessionID else {
            throw MuError.invalidTransition(
                "Claude Code native session identity changed before launch."
            )
        }
        run.nativeTurnID = turnID
        run.state = .active
        run.updatedAt = Date()
        binding.state = .working
        binding.lastActivitySummary =
            "Claude Code is working in the bounded Project workspace."
        binding.updatedAt = Date()
        try store.withTransaction {
            try store.upsertRun(run)
            try store.upsertRuntimeSessionBinding(binding)
            try store.appendEvent(
                LedgerEvent(
                    projectID: run.projectID,
                    actorID: run.actorID,
                    principalID: run.principalID,
                    workspaceID: run.workspaceID,
                    taskID: run.taskID,
                    runID: run.id,
                    type: "claude.turn.started",
                    summary:
                        "Claude Code started a native read-only turn.",
                    payload: [
                        "native_session_id": sessionID,
                        "mu_turn_id": turnID,
                        "binding_id": bindingID.uuidString
                    ]
                )
            )
        }
    }

    func persistClaudeCodeVisibleText(
        entryID: UUID,
        bindingID: UUID,
        text: String,
        force: Bool,
        runtimeName: String = "Claude Code"
    ) throws {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              var entry = try store.fetchChatEntry(id: entryID),
              var binding =
                try store.fetchRuntimeSessionBinding(
                    id: bindingID
                ) else {
            return
        }
        guard force || entry.text != trimmed else { return }
        entry.text = trimmed
        entry.deliveryState = force ? .mirrored : .routing
        entry.updatedAt = Date()
        binding.state = force ? .completed : .working
        binding.lastActivitySummary = force
            ? "\(runtimeName) produced its final visible result."
            : "\(runtimeName) is streaming visible output."
        binding.updatedAt = Date()
        try store.withTransaction {
            try store.upsertChatEntry(entry)
            try store.upsertRuntimeSessionBinding(binding)
        }
    }
}

final class ClaudeCodeOutputMirror:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let minimumInterval: TimeInterval = 0.10
    private var lastPersistedAt = Date.distantPast
    private var lastPersistedText = ""
    private let persist:
        @Sendable (String, Bool) -> Void

    init(
        persist: @escaping @Sendable (String, Bool) -> Void
    ) {
        self.persist = persist
    }

    func offer(_ text: String) {
        let payload: String? = lock.withLock {
            guard text != lastPersistedText,
                  Date().timeIntervalSince(
                      lastPersistedAt
                  ) >= minimumInterval else {
                return nil
            }
            lastPersistedText = text
            lastPersistedAt = Date()
            return text
        }
        if let payload {
            persist(payload, false)
        }
    }

    func finish(_ text: String) {
        lock.withLock {
            lastPersistedText = text
            lastPersistedAt = Date()
        }
        persist(text, true)
    }
}
