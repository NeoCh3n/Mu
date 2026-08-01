import Foundation

private struct RuntimeContextGatewayScope {
    var binding: RuntimeSessionBinding
    var run: RunRecord
    var pack: ProjectContextPackRecord
}

extension ControlPlaneService {
    /// Runtime-facing Context retrieval. The caller supplies only its opaque
    /// Mu binding identity; Project, Task, Actor, Principal, Endpoint, Run,
    /// Workspace, Lease, and Pack identity are derived from persisted state.
    public func runtimeContextSearch(
        bindingID: UUID,
        query: String,
        limit: Int = 20
    ) throws -> [ContextSearchResult] {
        try store.withTransaction {
            let scope = try authorizeRuntimeContextGateway(
                bindingID: bindingID,
                operation: .searchContext
            )
            return try searchContext(
                projectID: scope.pack.projectID,
                taskID: scope.pack.taskID,
                actorID: scope.binding.actorID!,
                query: query,
                limit: limit
            )
        }
    }

    /// Runtime-facing exact-record retrieval. A missing or policy-hidden
    /// record returns nil without revealing which case occurred.
    public func runtimeContextRecord(
        bindingID: UUID,
        recordID: UUID
    ) throws -> ContextSearchResult? {
        try store.withTransaction {
            let scope = try authorizeRuntimeContextGateway(
                bindingID: bindingID,
                operation: .getContextRecord
            )
            return try getContextRecord(
                projectID: scope.pack.projectID,
                taskID: scope.pack.taskID,
                actorID: scope.binding.actorID!,
                recordID: recordID
            )
        }
    }

    private func authorizeRuntimeContextGateway(
        bindingID: UUID,
        operation: RuntimeGatewayOperation
    ) throws -> RuntimeContextGatewayScope {
        guard let binding = try store.fetchRuntimeSessionBinding(
            id: bindingID
        ) else {
            throw MuError.recordNotFound(
                "Runtime binding \(bindingID)"
            )
        }
        guard binding.state == .working,
              let projectID = binding.projectID,
              let workspaceID = binding.workspaceID,
              let actorID = binding.actorID,
              let principalID = binding.principalID,
              let runID = binding.runID,
              let packID = binding.contextPackID else {
            throw MuError.invalidTransition(
                "Runtime Context requires an active, fully scoped binding."
            )
        }
        guard let endpoint = try store.fetchRegisteredEndpoint(
            id: binding.endpointID
        ), endpoint.status == .active else {
            throw MuError.invalidTransition(
                "Runtime Context requires the binding's active endpoint."
            )
        }
        try RuntimeGatewayRegistry.require(
            operation,
            endpoint: endpoint
        )
        guard let run = try store.fetchRun(id: runID),
              run.state == .active,
              run.id == binding.runID,
              run.taskID == binding.taskID,
              run.projectID == projectID,
              run.workspaceID == workspaceID,
              run.actorID == actorID,
              run.principalID == principalID,
              run.endpointID == binding.endpointID,
              run.contextPackID == packID else {
            throw MuError.invalidTransition(
                "Runtime Context requires the binding's exact active Run."
            )
        }
        guard let actor = try store.fetchProjectActor(id: actorID),
              actor.status == .active,
              actor.principalID == principalID,
              actor.runtimeEndpointID == binding.endpointID else {
            throw MuError.invalidTransition(
                "Runtime Context Actor is not bound to this endpoint."
            )
        }
        guard let task = try store.fetchTask(id: binding.taskID),
              task.projectID == projectID,
              task.workspaceID == workspaceID,
              task.currentRunID == run.id,
              task.currentEndpointID == binding.endpointID,
              !task.status.isTerminal else {
            throw MuError.invalidTransition(
                "Runtime Context Task is outside the active binding."
            )
        }
        guard let workspace = try store.fetchProjectWorkspace(
            id: workspaceID
        ), workspace.projectID == projectID,
        workspace.taskID == binding.taskID,
        workspace.status == .active else {
            throw MuError.invalidTransition(
                "Runtime Context Workspace is outside the active binding."
            )
        }
        guard let pack = try store.fetchProjectContextPack(
            projectID: projectID,
            id: packID
        ),
        pack.taskID == binding.taskID,
        pack.workspaceID == workspaceID,
        pack.actorID == actorID,
        pack.principalID == principalID,
        pack.runtimeEndpointID == binding.endpointID,
        pack.runtimeBindingID == binding.id,
        pack.taskLeaseID == binding.taskLeaseID,
        pack.selectionPolicyVersion?.isEmpty == false,
        pack.tokenBudget != nil,
        pack.contextRevision?.isEmpty == false,
        pack.taskRevision?.isEmpty == false,
        pack.policyRevision?.isEmpty == false,
        pack.itemSetFingerprint?.isEmpty == false,
        pack.budgetEstimatorVersion?.isEmpty == false,
        pack.canonicalizationVersion?.isEmpty == false,
        pack.includedContextRecordIDs != nil,
        pack.unresolvedContextConflictIDs != nil,
        pack.contextPackItemIDs != nil,
        let renderedArtifactURI = pack.renderedArtifactURI,
        pack.contentSHA256
            == Data(pack.renderedMarkdown.utf8).muSHA256,
        artifactStore.verify(
            uri: renderedArtifactURI,
            expectedSHA256: pack.contentSHA256
        ) else {
            throw MuError.invalidTransition(
                "Runtime Context requires the exact governed Context Pack."
            )
        }
        let packItems = try store.fetchContextPackItems(
            projectID: projectID,
            packID: pack.id
        )
        guard !packItems.isEmpty,
              packItems.map(\.id) == pack.contextPackItemIDs,
              packItems.enumerated().allSatisfy({
                  $0.offset == $0.element.ordinal
              }) else {
            throw MuError.invalidTransition(
                "Runtime Context Pack item receipts are incomplete or reordered."
            )
        }
        if let leaseID = binding.taskLeaseID {
            guard let lease = try store.fetchTaskLease(id: leaseID),
                  lease.projectID == projectID,
                  lease.taskID == binding.taskID,
                  lease.agentActorID == actorID,
                  lease.endpointID == binding.endpointID,
                  lease.runtimeBindingID == binding.id,
                  lease.fencingToken == pack.leaseFencingToken,
                  lease.isActive() else {
                throw MuError.invalidTransition(
                    "Runtime Context requires the Pack's active fenced lease."
                )
            }
        } else {
            throw MuError.invalidTransition(
                "Runtime Context requires a governed Pack Task lease."
            )
        }
        let delivered = try store.fetchContextDeliveries(
            projectID: projectID,
            taskID: binding.taskID
        ).contains {
            $0.status == .delivered
                && $0.contextPackID == pack.id
                && $0.runtimeBindingID == binding.id
                && $0.runID == run.id
                && $0.endpointID == binding.endpointID
                && $0.actorID == actorID
                && $0.principalID == principalID
                && $0.workspaceID == workspaceID
                && $0.taskLeaseID == binding.taskLeaseID
                && $0.leaseFencingToken == pack.leaseFencingToken
                && $0.contextRevision == pack.contextRevision
                && $0.policyRevision == pack.policyRevision
                && $0.packContentSHA256 == pack.contentSHA256
                && $0.adapterReceiptSHA256 != nil
        }
        guard delivered else {
            throw MuError.invalidTransition(
                "Runtime Context is unavailable until the exact Pack has a "
                    + "delivered adapter receipt."
            )
        }
        return RuntimeContextGatewayScope(
            binding: binding,
            run: run,
            pack: pack
        )
    }
}
