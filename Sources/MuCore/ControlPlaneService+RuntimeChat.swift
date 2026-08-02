import Foundation

extension ControlPlaneService {
    @discardableResult
    public func dispatchCodexWorkspaceMessage(
        entryID: UUID
    ) throws -> CodexTurnResult {
        let state = try beginManagedContinuation(
            entryID: entryID,
            runtimeTypeID: Self.codexRuntimeTypeID,
            nativeAgentName: "Codex"
        )
        guard state.endpoint.nativeConfiguration?["executable"] != nil else {
            let error = MuError.commandFailed(
                "Codex executable path is not registered."
            )
            failManagedContinuation(
                state: state,
                error: error
            )
            throw error
        }
        let client = try codexClient(for: state.endpoint)
        codexRuntimeLock.withLock {
            activeCodexClients[state.run.id] = client
        }
        defer {
            _ = codexRuntimeLock.withLock {
                activeCodexClients.removeValue(
                    forKey: state.run.id
                )
            }
        }
        let mirror = ClaudeCodeOutputMirror {
            [weak self] text, force in
            guard let self else { return }
            try? self.persistClaudeCodeVisibleText(
                entryID: state.response.id,
                bindingID: state.binding.id,
                text: text,
                force: force,
                runtimeName: "Codex"
            )
        }
        do {
            try recordContextDelivery(
                projectID: state.kernel.project.id,
                packID: state.contextPack.id,
                status: .prepared
            )
            let prompt =
                state.contextPack.renderedMarkdown
                + "\n\n# Current Project message\n\n"
                + (state.entry.routedText
                    ?? state.entry.text)
            let result: CodexTurnResult
            do {
                result = try client.runReadOnlyContinuation(
                    threadID: state.binding.nativeSessionID,
                    task: state.task,
                    prompt: prompt,
                    clientUserMessageID:
                        state.entry.id.uuidString,
                    onTurnStarted: {
                        [weak self] threadID, turnID in
                        try self?.markManagedContinuationStarted(
                            state: state,
                            nativeSessionID: threadID,
                            nativeTurnID: turnID
                        )
                    },
                    onVisibleText: { text in
                        mirror.offer(text)
                    }
                )
            } catch {
                guard Self.isMissingCodexThreadError(error) else {
                    throw error
                }

                // A persisted native thread can disappear when the Codex App
                // Server is restarted or its state database is replaced. The
                // Project message remains valid, so recover it exactly once by
                // creating a replacement thread with the same bounded prompt.
                let previousNativeSessionID = state.binding.nativeSessionID
                result = try client.runReadOnlyTask(
                    task: state.task,
                    agent: nil,
                    promptOverride: prompt,
                    clientUserMessageID:
                        state.entry.id.uuidString,
                    onThreadStarted: {
                        [weak self] nativeSessionID in
                        try self?.markManagedContinuationSessionReplaced(
                            state: state,
                            previousNativeSessionID:
                                previousNativeSessionID,
                            nativeSessionID: nativeSessionID
                        )
                    },
                    onTurnStarted: {
                        [weak self] threadID, turnID in
                        try self?.markManagedContinuationStarted(
                            state: state,
                            nativeSessionID: threadID,
                            nativeTurnID: turnID
                        )
                    },
                    onVisibleText: { text in
                        mirror.offer(text)
                    }
                )
            }
            mirror.finish(result.output)
            try completeManagedContinuation(
                state: state,
                output: result.output,
                nativeSessionID: result.threadID,
                nativeTurnID: result.turnID,
                nativeStatus: result.status,
                provider: .codex,
                model: nil,
                errorMessage: result.errorMessage
            )
            return result
        } catch {
            failManagedContinuation(
                state: state,
                error: error
            )
            throw error
        }
    }

    @discardableResult
    public func dispatchClaudeCodeWorkspaceMessage(
        entryID: UUID
    ) throws -> ClaudeCodeTurnResult {
        let state = try beginManagedContinuation(
            entryID: entryID,
            runtimeTypeID: Self.claudeCodeRuntimeTypeID,
            nativeAgentName: "Claude Code"
        )
        guard let executable =
            state.endpoint.nativeConfiguration?["executable"] else {
            let error = MuError.commandFailed(
                "Claude Code executable path is not registered."
            )
            failManagedContinuation(
                state: state,
                error: error
            )
            throw error
        }
        let client = ClaudeCodeClient(
            executableURL: URL(fileURLWithPath: executable)
        )
        claudeRuntimeLock.withLock {
            activeClaudeClients[state.run.id] = client
        }
        defer {
            _ = claudeRuntimeLock.withLock {
                activeClaudeClients.removeValue(
                    forKey: state.run.id
                )
            }
        }
        let mirror = ClaudeCodeOutputMirror {
            [weak self] text, force in
            guard let self else { return }
            try? self.persistClaudeCodeVisibleText(
                entryID: state.response.id,
                bindingID: state.binding.id,
                text: text,
                force: force,
                runtimeName: "Claude Code"
            )
        }
        do {
            try recordContextDelivery(
                projectID: state.kernel.project.id,
                packID: state.contextPack.id,
                status: .prepared
            )
            let prompt =
                state.contextPack.renderedMarkdown
                + "\n\n# Current Project message\n\n"
                + (state.entry.routedText
                    ?? state.entry.text)
            let result = try client.runReadOnlyTask(
                task: state.task,
                contextPack: state.contextPack,
                sessionID:
                    state.binding.nativeSessionID,
                resumeSessionID:
                    state.binding.nativeSessionID,
                promptOverride: prompt,
                onSessionStarted: {
                    [weak self] nativeSessionID in
                    try self?.markManagedContinuationStarted(
                        state: state,
                        nativeSessionID: nativeSessionID,
                        nativeTurnID:
                            state.run.nativeTurnID
                            ?? UUID().uuidString
                                .lowercased()
                    )
                },
                onVisibleText: { text in
                    mirror.offer(text)
                }
            )
            try recordContextDelivery(
                projectID: state.kernel.project.id,
                packID: state.contextPack.id,
                status: .delivered,
                adapterReceiptMaterial:
                    "claude-code|\(result.sessionID)|"
                    + "\(state.run.nativeTurnID ?? "")|\(result.status)"
            )
            mirror.finish(result.output)
            let turnID =
                (try store.fetchRun(id: state.run.id))?
                .nativeTurnID
                ?? UUID().uuidString.lowercased()
            try completeManagedContinuation(
                state: state,
                output: result.output,
                nativeSessionID: result.sessionID,
                nativeTurnID: turnID,
                nativeStatus: result.status,
                provider: .claudeCode,
                model: result.model,
                errorMessage: result.errorMessage
            )
            return result
        } catch {
            failManagedContinuation(
                state: state,
                error: error
            )
            throw error
        }
    }

    public func interruptCodexRun(runID: UUID) throws {
        guard let run = try store.fetchRun(id: runID),
              let endpoint =
                try store.fetchRegisteredEndpoint(
                    id: run.endpointID
                ),
              endpoint.runtimeTypeID
                == Self.codexRuntimeTypeID else {
            throw MuError.recordNotFound(
                "Active Codex Run \(runID)"
            )
        }
        try RuntimeGatewayRegistry.require(
            .interrupt,
            endpoint: endpoint
        )
        guard let threadID = run.nativeThreadID,
              let turnID = run.nativeTurnID,
              let client = codexRuntimeLock.withLock({
                  activeCodexClients[runID]
              }) else {
            throw MuError.invalidTransition(
                "Codex is not currently executing this Run."
            )
        }
        try client.interrupt(
            threadID: threadID,
            turnID: turnID
        )
        try store.appendEvent(
            LedgerEvent(
                projectID: run.projectID,
                actorID: run.actorID,
                principalID: run.principalID,
                workspaceID: run.workspaceID,
                taskID: run.taskID,
                runID: run.id,
                type: "codex.turn.interrupt_requested",
                summary:
                    "Requested interruption through the official Codex App Server.",
                payload: [
                    "native_thread_id": threadID,
                    "native_turn_id": turnID
                ]
            )
        )
    }

    /// Converts a first-message entry that waited while an initial native Run
    /// was already starting into the normal continuation shape. This keeps a
    /// fast composer submit from losing the user's message to a race between
    /// Project creation and native session binding.
    @discardableResult
    public func promoteWorkspaceMessageToManagedContinuation(
        entryID: UUID
    ) throws -> ChatEntry {
        guard var entry = try store.fetchChatEntry(id: entryID),
              entry.deliveryState == .awaitingSession,
              let endpointID = entry.targetEndpointID,
              let task = try store.fetchTask(id: entry.taskID),
              let endpoint = try store.fetchRegisteredEndpoint(id: endpointID),
              endpoint.runtimeTypeID == Self.codexRuntimeTypeID
                || endpoint.runtimeTypeID == Self.claudeCodeRuntimeTypeID,
              let binding = try currentRuntimeSessionBinding(
                  taskID: task.id,
                  endpointID: endpoint.id,
                  agentIdentityID: entry.targetAgentIdentityID
              ) else {
            throw MuError.invalidTransition(
                "The native Runtime session is not ready for this Workspace message."
            )
        }
        guard binding.state != .detached,
              binding.state != .failed,
              binding.state != .disconnected else {
            throw MuError.invalidTransition(
                "The native Runtime session ended before this Workspace message could start."
            )
        }
        guard binding.state != .connecting,
              binding.state != .working,
              binding.state != .awaitingApproval else {
            throw MuError.invalidTransition(
                "The native Runtime session is still working."
            )
        }
        guard WorkspacePathIdentity.isExactMatch(
            binding.workspacePath,
            task.repositoryPath
        ) else {
            throw MuError.invalidTransition(
                "The native Runtime session belongs to another Project workspace."
            )
        }
        let kernel = try projectKernelContext(taskID: task.id)
        let actorID = binding.actorID ?? kernel.actor?.id
        guard let actorID else {
            throw MuError.invalidTransition(
                "The native Runtime has no authorized Project Actor."
            )
        }
        let run = RunRecord(
            taskID: task.id,
            projectID: kernel.project.id,
            workspaceID: kernel.workspace.id,
            actorID: actorID,
            principalID: binding.principalID ?? kernel.principal?.id,
            endpointID: endpoint.id,
            actorName: binding.nativeAgentName,
            purpose: .delegation,
            state: .starting,
            nativeThreadID: binding.nativeSessionID,
            agentIdentityID: entry.targetAgentIdentityID
        )
        entry.runID = run.id
        entry.runtimeSessionBindingID = binding.id
        entry.nativeMessageIndexLowerBound = binding.lastSyncedMessageCount
        entry.deliveryState = .queued
        entry.updatedAt = Date()
        try store.withTransaction {
            try store.upsertRun(run)
            try store.upsertChatEntry(entry)
            try store.appendEvent(
                LedgerEvent(
                    projectID: kernel.project.id,
                    actorID: actorID,
                    principalID: run.principalID,
                    workspaceID: kernel.workspace.id,
                    taskID: task.id,
                    runID: run.id,
                    type: "runtime.message.queued",
                    summary:
                        "Queued the first Workspace message after the native session became resumable.",
                    payload: [
                        "chat_entry_id": entry.id.uuidString,
                        "binding_id": binding.id.uuidString,
                        "native_session_id": binding.nativeSessionID
                    ]
                )
            )
        }
        return entry
    }

    private func beginManagedContinuation(
        entryID: UUID,
        runtimeTypeID: String,
        nativeAgentName: String
    ) throws -> ManagedContinuationState {
        guard var entry = try store.fetchChatEntry(id: entryID),
              entry.deliveryState == .queued,
              let bindingID =
                entry.runtimeSessionBindingID,
              var binding =
                try store.fetchRuntimeSessionBinding(
                    id: bindingID
                ),
              binding.state != .working,
              binding.state != .awaitingApproval,
              var run = try entry.runID.flatMap({
                  try store.fetchRun(id: $0)
              }),
              run.state == .starting,
              var task = try store.fetchTask(
                  id: entry.taskID
              ),
              let endpoint =
                try store.fetchRegisteredEndpoint(
                    id: binding.endpointID
                ),
              endpoint.runtimeTypeID == runtimeTypeID,
              endpoint.id == entry.targetEndpointID else {
            throw MuError.invalidTransition(
                "\(nativeAgentName) Workspace message is not safely queued."
            )
        }
        try RuntimeGatewayRegistry.require(
            .submitInput,
            endpoint: endpoint
        )
        try RuntimeGatewayRegistry.require(
            .resume,
            endpoint: endpoint
        )
        guard WorkspacePathIdentity.isExactMatch(
            binding.workspacePath,
            task.repositoryPath
        ) else {
            throw MuError.invalidTransition(
                "\(nativeAgentName) session belongs to another Project workspace."
            )
        }
        let kernel = try projectKernelContext(
            taskID: task.id
        )
        guard let actorID =
            binding.actorID
            ?? run.actorID
            ?? kernel.actor?.id else {
            throw MuError.invalidTransition(
                "\(nativeAgentName) has no authorized Project Actor."
            )
        }
        let lease = try claimTaskLease(
            taskID: task.id,
            endpointID: endpoint.id,
            actorID: actorID,
            runtimeBindingID: binding.id,
            duration: 30 * 60
        )
        let contextPack = try buildGovernedContextPack(
            taskID: task.id,
            actorID: actorID,
            endpointID: endpoint.id,
            runtimeBindingID: binding.id,
            taskLeaseID: lease.id
        )
        let response = ChatEntry(
            taskID: task.id,
            agentIdentityID:
                entry.targetAgentIdentityID,
            runID: run.id,
            runtimeSessionBindingID: binding.id,
            deliveryState: .routing,
            authorKind: .agent,
            authorName: run.actorName,
            text: "\(nativeAgentName) is working…"
        )
        entry.deliveryState = .sending
        entry.updatedAt = Date()
        run.projectID = kernel.project.id
        run.workspaceID = kernel.workspace.id
        run.actorID = actorID
        run.principalID =
            binding.principalID
            ?? kernel.principal?.id
        run.taskLeaseID = lease.id
        run.contextPackID = contextPack.id
        run.nativeThreadID =
            binding.nativeSessionID
        run.nativeTurnID =
            runtimeTypeID
                == Self.claudeCodeRuntimeTypeID
            ? UUID().uuidString.lowercased()
            : nil
        run.state = .active
        run.updatedAt = Date()
        binding.projectID = kernel.project.id
        binding.workspaceID = kernel.workspace.id
        binding.actorID = actorID
        binding.principalID = run.principalID
        binding.taskLeaseID = lease.id
        binding.runID = run.id
        binding.contextPackID = contextPack.id
        binding.state = .working
        binding.lastActivitySummary =
            "\(nativeAgentName) is handling a bounded Project message."
        binding.lastError = nil
        binding.updatedAt = Date()
        task.currentRunID = run.id
        task.currentEndpointID = endpoint.id
        task.assignedActorID = actorID
        task.status = .running
        task.updatedAt = Date()
        var updatedLease = lease
        updatedLease.runtimeBindingID = binding.id
        do {
            try store.withTransaction {
                try store.upsertChatEntry(entry)
                try store.insertChatEntry(response)
                try store.upsertRun(run)
                try store.upsertTask(task)
                try store.upsertRuntimeSessionBinding(
                    binding
                )
                try store.upsertTaskLease(updatedLease)
                try store.appendEvent(
                    LedgerEvent(
                        projectID: kernel.project.id,
                        actorID: actorID,
                        principalID: run.principalID,
                        workspaceID: kernel.workspace.id,
                        taskID: task.id,
                        runID: run.id,
                        type:
                            "\(nativeAgentName.lowercased().replacingOccurrences(of: " ", with: "_")).message.dispatching",
                        summary:
                            "Dispatching a bounded Project message to \(nativeAgentName).",
                        payload: [
                            "chat_entry_id":
                                entry.id.uuidString,
                            "response_entry_id":
                                response.id.uuidString,
                            "binding_id":
                                binding.id.uuidString,
                            "lease_id":
                                lease.id.uuidString,
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
        return ManagedContinuationState(
            entry: entry,
            response: response,
            task: task,
            run: run,
            endpoint: endpoint,
            binding: binding,
            lease: updatedLease,
            contextPack: contextPack,
            kernel: kernel,
            nativeAgentName: nativeAgentName
        )
    }

    private func markManagedContinuationStarted(
        state: ManagedContinuationState,
        nativeSessionID: String,
        nativeTurnID: String
    ) throws {
        guard !nativeSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              var run = try store.fetchRun(
                  id: state.run.id
              ),
              var binding =
                try store.fetchRuntimeSessionBinding(
                    id: state.binding.id
                ),
              binding.nativeSessionID == nativeSessionID else {
            throw MuError.invalidTransition(
                "\(state.nativeAgentName) returned a conflicting session identity."
            )
        }
        run.nativeThreadID = nativeSessionID
        run.nativeTurnID = nativeTurnID
        run.state = .active
        run.updatedAt = Date()
        binding.state = .working
        binding.lastActivitySummary =
            "\(state.nativeAgentName) native turn started."
        binding.updatedAt = Date()
        try store.withTransaction {
            try store.upsertRun(run)
            try store.upsertRuntimeSessionBinding(
                binding
            )
        }
        if state.endpoint.runtimeTypeID
            != Self.claudeCodeRuntimeTypeID {
            try recordContextDelivery(
                projectID: state.kernel.project.id,
                packID: state.contextPack.id,
                status: .delivered,
                adapterReceiptMaterial:
                    "\(state.nativeAgentName)|\(nativeSessionID)|\(nativeTurnID)"
            )
        }
    }

    private func markManagedContinuationSessionReplaced(
        state: ManagedContinuationState,
        previousNativeSessionID: String,
        nativeSessionID: String
    ) throws {
        let previousID = previousNativeSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let replacementID = nativeSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !previousID.isEmpty,
              !replacementID.isEmpty,
              previousID != replacementID,
              var run = try store.fetchRun(id: state.run.id),
              var binding = try store.fetchRuntimeSessionBinding(
                  id: state.binding.id
              ),
              binding.nativeSessionID == previousID else {
            throw MuError.invalidTransition(
                "\(state.nativeAgentName) returned a conflicting replacement session identity."
            )
        }

        run.nativeThreadID = replacementID
        run.nativeTurnID = nil
        run.updatedAt = Date()
        binding.nativeSessionID = replacementID
        binding.state = .connecting
        binding.lastActivitySummary =
            "\(state.nativeAgentName) replaced an unavailable native thread."
        binding.lastError = nil
        binding.updatedAt = Date()
        try store.withTransaction {
            try store.upsertRun(run)
            try store.upsertRuntimeSessionBinding(binding)
            try store.appendEvent(
                LedgerEvent(
                    projectID: state.kernel.project.id,
                    actorID: run.actorID,
                    principalID: run.principalID,
                    workspaceID: state.kernel.workspace.id,
                    taskID: state.task.id,
                    runID: run.id,
                    type: "codex.thread.replaced",
                    summary:
                        "Codex replaced an unavailable native Project thread.",
                    payload: [
                        "previous_native_thread_id": previousID,
                        "native_thread_id": replacementID,
                        "reason": "thread_not_found"
                    ]
                )
            )
        }
    }

    private static func isMissingCodexThreadError(_ error: Error) -> Bool {
        let message = [
            error.localizedDescription,
            String(describing: error)
        ]
        .joined(separator: " ")
        .lowercased()
        return message.contains("thread not found")
            || message.contains("thread_not_found")
            || message.contains("unknown thread")
    }

    private func completeManagedContinuation(
        state: ManagedContinuationState,
        output: String,
        nativeSessionID: String,
        nativeTurnID: String,
        nativeStatus: String,
        provider: ConversationProvider,
        model: String?,
        errorMessage: String?
    ) throws {
        guard var entry = try store.fetchChatEntry(
                  id: state.entry.id
              ),
              var response = try store.fetchChatEntry(
                  id: state.response.id
              ),
              var run = try store.fetchRun(
                  id: state.run.id
              ),
              var task = try store.fetchTask(
                  id: state.task.id
              ),
              var binding =
                try store.fetchRuntimeSessionBinding(
                    id: state.binding.id
                ) else {
            throw MuError.recordNotFound(
                "\(state.nativeAgentName) continuation state"
            )
        }
        let wasCancelled =
            nativeStatus == "cancelled"
            || nativeStatus == "interrupted"
        entry.deliveryState =
            wasCancelled ? .cancelled : .delivered
        entry.updatedAt = Date()
        response.text = output
        response.deliveryState =
            wasCancelled ? .cancelled : .mirrored
        response.updatedAt = Date()
        run.nativeThreadID = nativeSessionID
        run.nativeTurnID = nativeTurnID
        run.nativeOutput = output
        run.state = wasCancelled
            ? .cancelled
            : .completed
        run.updatedAt = Date()
        task.status = wasCancelled
            ? .cancelled
            : .completed
        task.updatedAt = Date()
        binding.nativeSessionID = nativeSessionID
        binding.model = model ?? binding.model
        binding.state = wasCancelled
            ? .disconnected
            : .completed
        binding.lastActivitySummary =
            wasCancelled
            ? "\(state.nativeAgentName) was interrupted."
            : "\(state.nativeAgentName) completed the native turn."
        binding.lastError = errorMessage
        binding.updatedAt = Date()
        let artifact = try submitRuntimeOutputArtifact(
            taskID: task.id,
            producerActorID: run.actorID,
            title:
                "\(state.nativeAgentName) result · \(task.title)",
            output: output,
            metadata: [
                "provider": provider.rawValue,
                "native_session_id": nativeSessionID,
                "native_turn_id": nativeTurnID,
                "native_status": nativeStatus,
                "model": model ?? ""
            ]
        )
        try store.withTransaction {
            try store.upsertChatEntry(entry)
            try store.upsertChatEntry(response)
            try store.upsertRun(run)
            try store.upsertTask(task)
            try store.upsertRuntimeSessionBinding(
                binding
            )
            try store.appendEvent(
                LedgerEvent(
                    projectID:
                        state.kernel.project.id,
                    actorID: run.actorID,
                    principalID: run.principalID,
                    workspaceID:
                        state.kernel.workspace.id,
                    artifactID: artifact.id,
                    taskID: task.id,
                    runID: run.id,
                    type:
                        "\(provider.rawValue).message.completed",
                    summary:
                        "\(state.nativeAgentName) published a reviewable Project result.",
                    payload: [
                        "native_session_id":
                            nativeSessionID,
                        "native_turn_id":
                            nativeTurnID,
                        "artifact_id":
                            artifact.id.uuidString,
                        "native_status":
                            nativeStatus
                    ]
                )
            )
        }
        _ = try? releaseTaskLease(
            id: state.lease.id
        )
    }

    private func failManagedContinuation(
        state: ManagedContinuationState,
        error: Error
    ) {
        var entry = try? store.fetchChatEntry(
            id: state.entry.id
        )
        var response = try? store.fetchChatEntry(
            id: state.response.id
        )
        var run = try? store.fetchRun(id: state.run.id)
        var task = try? store.fetchTask(id: state.task.id)
        var binding =
            try? store.fetchRuntimeSessionBinding(
                id: state.binding.id
            )
        entry?.deliveryState = .failed
        entry?.updatedAt = Date()
        response?.deliveryState = .failed
        response?.text =
            "\(state.nativeAgentName) failed: "
            + error.localizedDescription
        response?.updatedAt = Date()
        run?.state = .failed
        run?.updatedAt = Date()
        task?.status = .failed
        task?.updatedAt = Date()
        binding?.state = .failed
        binding?.lastError = error.localizedDescription
        binding?.lastActivitySummary =
            "\(state.nativeAgentName) continuation failed."
        binding?.updatedAt = Date()
        try? store.withTransaction {
            if let entry {
                try store.upsertChatEntry(entry)
            }
            if let response {
                try store.upsertChatEntry(response)
            }
            if let run {
                try store.upsertRun(run)
            }
            if let task {
                try store.upsertTask(task)
            }
            if let binding {
                try store.upsertRuntimeSessionBinding(
                    binding
                )
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID:
                        state.kernel.project.id,
                    actorID: state.run.actorID,
                    principalID:
                        state.run.principalID,
                    workspaceID:
                        state.kernel.workspace.id,
                    taskID: state.task.id,
                    runID: state.run.id,
                    type:
                        "\(state.nativeAgentName.lowercased().replacingOccurrences(of: " ", with: "_")).message.failed",
                    summary:
                        "\(state.nativeAgentName) continuation failed.",
                    payload: [
                        "error":
                            error.localizedDescription,
                        "automatic_retry": "disabled"
                    ]
                )
            )
        }
        _ = try? recordContextDelivery(
            projectID: state.kernel.project.id,
            packID: state.contextPack.id,
            status: .failed,
            failureCode: "managed_runtime_dispatch_failed"
        )
        _ = try? releaseTaskLease(
            id: state.lease.id
        )
    }
}

private struct ManagedContinuationState:
    Sendable
{
    var entry: ChatEntry
    var response: ChatEntry
    var task: TaskRecord
    var run: RunRecord
    var endpoint: RuntimeEndpoint
    var binding: RuntimeSessionBinding
    var lease: TaskLeaseRecord
    var contextPack: ProjectContextPackRecord
    var kernel: ProjectKernelTaskContext
    var nativeAgentName: String
}
