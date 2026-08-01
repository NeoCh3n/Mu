import { MuError } from '../errors.ts'
import { sha256Hex } from '../hashing.ts'
import { uuid, type UUID } from '../identity.ts'
import type { ContextRecord } from '../context-kernel/index.ts'
import {
  createContextConflictRecord,
  createContextRecord,
  createContextSourceRecord,
  pcvString,
  stableConflictID,
} from '../context-kernel/index.ts'
import type { Harness, HarnessTurnEvent, HarnessTurnInput } from '../harness/types.ts'
import { resolveReasoningEffort, type AgentRuntimeEndpointScope, type AgentRuntimeInstanceIdentity, type ReasoningEffort } from '../types.ts'
import { toAgentHostAdapter } from '../host-adapter/harness-adapter.ts'
import type { AgentHostAdapter, HostHistoryCandidate } from '../host-adapter/types.ts'
import {
  createAgentIdentity,
  createChatEntry,
  createCheckpointContent,
  createHandoffRecord,
  createRunRecord,
  createRuntimeArtifactRecord,
  createRuntimeEndpoint,
  createRuntimeInteractionRequest,
  createRuntimeSessionBinding,
  createTaskRecord,
  type AgentIdentity,
  type ChatEntry,
  type HandoffRecord,
  type RunRecord,
  type RuntimeArtifactRecord,
  type RuntimeEndpoint,
  type RuntimeInteractionRequest,
  type RuntimeSessionBinding,
  type TaskRecord,
} from '../models.ts'
import {
  fetchAgent,
  fetchAgents,
  fetchChatEntries,
  fetchEndpoint,
  fetchEndpoints,
  fetchHandoffs,
  fetchProjectApprovals,
  fetchProjects,
  fetchProjectContextPack,
  fetchRun,
  fetchRuns,
  fetchRuntimeArtifacts,
  fetchRuntimeInteractions,
  fetchRuntimeSessionBindings,
  fetchTask,
  fetchTasks,
  insertChatEntry,
  insertCheckpoint,
  insertProjectContextPack,
  upsertAgent,
  upsertEndpoint,
  upsertHandoff,
  upsertProject,
  upsertProjectApproval,
  upsertProjectReview,
  upsertRun,
  upsertRuntimeArtifact,
  upsertRuntimeInteraction,
  upsertRuntimeSessionBinding,
  upsertTask,
  upsertTaskLease,
} from '../persistence/domain.ts'
import type { SQLiteStore } from '../persistence/store.ts'
import {
  createProjectApprovalRecord,
  createProjectReviewRecord,
  createTaskLeaseRecord,
  type ProjectApprovalRecord,
  type ProjectReviewRecord,
  type TaskLeaseRecord,
} from '../project-kernel/index.ts'
import {
  createProjectRecord,
  type ProjectRecord,
} from '../project-kernel/index.ts'
import type { ProjectContextPackRecord } from '../project-kernel/index.ts'
import {
  createRuntimeAdapterRegistration,
} from '../runtime-gateway/manifest.ts'
import {
  buildProjectContextPack,
  createDeliveryReceipt,
  fetchContextConflicts,
  fetchContextRecord,
  fetchContextRecords,
  transitionContextRecordStatus,
  upsertContextConflict,
  upsertContextRecord,
  upsertContextSource,
} from './context.ts'
import { appendLedger, fetchLedger } from './ledger.ts'

// ---------------------------------------------------------------------------
// Dependencies
// ---------------------------------------------------------------------------

export interface ControlPlaneDependencies {
  readonly store: SQLiteStore
  /** One harness per deployment (local mode or QM mode). */
  readonly harness: Harness
  /** Optional explicit host adapter; defaults to toAgentHostAdapter(harness). */
  readonly host?: AgentHostAdapter
  readonly now?: () => Date
  /** Observer for externally-visible events (e.g. server SSE in Phase 6). */
  readonly onEvent?: (event: ControlPlaneTurnEvent) => void
}

export interface ControlPlaneTurnEvent {
  readonly kind: 'run_created' | 'chat_entry'
  readonly run?: RunRecord
  readonly binding?: RuntimeSessionBinding
  readonly pack?: ProjectContextPackRecord
  readonly chatEntry?: ChatEntry
}

// ---------------------------------------------------------------------------
// Public API types
// ---------------------------------------------------------------------------

export interface ProbeOutcome {
  readonly endpointID: UUID
  readonly ok: boolean
  readonly message: string
}

export interface ImportContextRecordParams {
  readonly projectID: UUID
  readonly taskID?: UUID
  readonly kind: ContextRecord['kind']
  readonly subject: string
  readonly text: string
  readonly sourceActorID: UUID
  readonly sourcePrincipalID?: UUID
  readonly externalRef?: string
  readonly runtimeEndpointID?: UUID
  readonly runtimeSessionID?: string
  readonly confidence?: number
}

export interface ControlPlaneService {
  // Projects
  createProject(params: { displayName: string; repositoryPath?: string; ownerPrincipalID: UUID }): ProjectRecord
  listProjects(): ProjectRecord[]
  renameProject(projectID: UUID, displayName: string): ProjectRecord
  removeProject(projectID: UUID): ProjectRecord
  // Agents
  createAgent(params: {
    displayName: string
    shortName: string
    role: AgentIdentity['role']
    summary: string
    preferredEndpointID?: UUID
    capabilityTags?: readonly string[]
    accentHex?: string
  }): AgentIdentity
  listAgents(): AgentIdentity[]
  // Endpoints
  registerEndpoint(params: {
    runtimeTypeID: string
    displayName: string
    runtimeVersion: string
    location: RuntimeEndpoint['location']
    /** Explicit instance identity; defaults are derived from the runtime type. */
    instanceIdentity?: Partial<AgentRuntimeInstanceIdentity>
  }): RuntimeEndpoint
  listEndpoints(): RuntimeEndpoint[]
  // Tasks
  createTask(params: {
    projectID: UUID
    workspaceID?: UUID
    title: string
    objective: string
    repositoryPath: string
    assignedAgentIdentityID?: UUID
    requestedByActorID?: UUID
    successCriteria?: readonly string[]
    constraints?: readonly string[]
  }): TaskRecord
  listTasks(): TaskRecord[]
  fetchTask(taskID: UUID): TaskRecord | undefined
  // Turn dispatch
  runTaskTurn(params: {
    taskID: UUID
    endpointID?: UUID
    /** Reuse an immutable pack created for another task in the same project/workspace. */
    contextPackID?: UUID
    contextRecordIDs?: readonly UUID[]
    reasoningEffort?: ReasoningEffort
    text: string
    promptOverride?: string
    sessionID?: string
    resumeSessionID?: string
  }): AsyncGenerator<ControlPlaneTurnEvent | HarnessTurnEvent, void>
  interruptRun(runID: UUID): Promise<void>
  // Context
  importContextRecord(params: ImportContextRecordParams): ContextRecord
  reviewContextRecord(params: { recordID: UUID; decision: 'accepted' | 'rejected' | 'disputed'; actorID: UUID }): ContextRecord
    listContextRecords(projectID: UUID): ContextRecord[]
  buildContextPack(params: {
    projectID: UUID
    taskID: UUID
    workspaceID: UUID
    objective: string
    endpointID: UUID
    actorID: UUID
    principalID: UUID
    contextRecordIDs?: readonly UUID[]
  }): ProjectContextPackRecord
  resolveConflict(params: { conflictID: UUID; acceptedRecordIDs: readonly UUID[]; actorID: UUID; note?: string }): ContextConflictRecordLike
  // Approvals & reviews
  requestApproval(params: { projectID: UUID; taskID: UUID; scope: string; requestedByActorID: UUID }): ProjectApprovalRecord
  resolveApproval(params: { approvalID: UUID; decision: 'granted' | 'denied'; approverActorID: UUID; reason?: string }): ProjectApprovalRecord
  submitReview(params: {
    projectID: UUID
    taskID: UUID
    reviewerActorID: UUID
    verdict: 'approved' | 'changes_requested' | 'rejected'
    findings?: readonly string[]
  }): ProjectReviewRecord
  // Handoffs
  proposeHandoff(params: {
    taskID: UUID
    sourceEndpointID: UUID
    receiverEndpointID: UUID
    validationMessage: string
  }): HandoffRecord
  resolveHandoff(params: { handoffID: UUID; accepted: boolean; validationMessage: string; rejectionReason?: string }): HandoffRecord
  listHandoffs(taskID?: UUID): HandoffRecord[]
  // Ledger & queries
  fetchLedger(taskID?: UUID, limit?: number): ReturnType<typeof fetchLedger>
  listRuns(taskID?: UUID): RunRecord[]
  listChatEntries(taskID?: UUID): ChatEntry[]
  listSessionBindings(taskID?: UUID): RuntimeSessionBinding[]
  listRuntimeArtifacts(taskID?: UUID): RuntimeArtifactRecord[]
  /**
   * Discovers past host conversations for a workspace (host-internal
   * visibility; the query runs inside the same host process that ran the
   * turns). Returns [] when the host has no history surface.
   */
  discoverHistory(endpointID: UUID, workspacePath: string): Promise<HostHistoryCandidate[]>
  hydrateHistory(endpointID: UUID, candidate: HostHistoryCandidate): Promise<HostHistoryCandidate>
  /** Best-effort background warm-up for long-lived endpoint connections. */
  warmEndpoints(): Promise<void>
  probeEndpoints(): Promise<ProbeOutcome[]>
  close(): void
}

type ContextConflictRecordLike = ReturnType<typeof createContextConflictRecord>

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

export function createControlPlaneService(deps: ControlPlaneDependencies): ControlPlaneService {
  const store = deps.store
  const harness = deps.harness
  /** The control plane speaks only the AgentHostAdapter contract. */
  const host = deps.host ?? toAgentHostAdapter(harness)
  const now = deps.now ?? (() => new Date())
  const onEvent = deps.onEvent

  // Per-endpoint serialization: the local harness runs one active turn.
  const endpointQueues = new Map<UUID, Promise<void>>()

  function serializeOnEndpoint<T>(endpointID: UUID, work: () => Promise<T>): Promise<T> {
    const previous = endpointQueues.get(endpointID) ?? Promise.resolve()
    const next = previous.then(work, work)
    endpointQueues.set(
      endpointID,
      next.then(() => undefined, () => undefined),
    )
    return next
  }

  /** Holds the endpoint queue for the full host stream, not just preparation. */
  function streamOnEndpoint<T>(
    endpointID: UUID,
    work: () => AsyncIterable<T>,
  ): AsyncGenerator<T, void> {
    const previous = endpointQueues.get(endpointID) ?? Promise.resolve()
    let release!: () => void
    const current = new Promise<void>((resolve) => { release = resolve })
    endpointQueues.set(endpointID, current)
    return (async function* () {
      await previous
      try {
        for await (const item of work()) yield item
      } finally {
        if (endpointQueues.get(endpointID) === current) endpointQueues.delete(endpointID)
        release()
      }
    })()
  }

  function emit(event: ControlPlaneTurnEvent): void {
    onEvent?.(event)
  }

  function providerFor(endpoint: RuntimeEndpoint): { rawValue: string } {
    // Prefer the concrete instance identity (bootstrap sets
    // provider: codex / claude_code); nativeConfiguration is the fallback.
    return {
      rawValue: endpoint.instanceIdentity?.provider.rawValue
        ?? endpoint.nativeConfiguration?.['provider']
        ?? 'claude_code',
    }
  }

  function endpointScope(endpoint: RuntimeEndpoint): AgentRuntimeEndpointScope {
    if (endpoint.instanceIdentity === undefined) {
      throw MuError.invalidTransition(
        `Endpoint ${endpoint.id} has no instance identity and cannot be used by a host.`,
      )
    }
    return {
      endpointID: endpoint.id,
      runtimeTypeID: endpoint.runtimeTypeID,
      displayName: endpoint.displayName,
      instanceIdentity: endpoint.instanceIdentity,
    }
  }

  return {
    // -----------------------------------------------------------------------
    // Projects
    // -----------------------------------------------------------------------

    createProject(params) {
      const project = createProjectRecord({
        displayName: params.displayName,
        repositoryPath: params.repositoryPath,
        ownerPrincipalID: params.ownerPrincipalID,
        createdAt: now(),
        updatedAt: now(),
      })
      upsertProject(store, project)
      appendLedger(store, {
        type: 'project.created',
        summary: `Created project "${project.displayName}".`,
        projectID: project.id,
        principalID: params.ownerPrincipalID,
        occurredAt: now(),
      })
      return project
    },

    listProjects() {
      return fetchProjects(store)
    },

    renameProject(projectID, displayName) {
      const project = fetchProjects(store).find((candidate) => candidate.id === projectID)
      if (project === undefined) {
        throw MuError.recordNotFound(`Project ${projectID} was not found.`)
      }
      const normalized = displayName.trim()
      if (normalized === '') {
        throw MuError.invalidTransition('Project display name cannot be empty.')
      }
      const renamed = { ...project, displayName: normalized, updatedAt: now() }
      upsertProject(store, renamed)
      appendLedger(store, {
        type: 'project.renamed',
        summary: `Renamed project to "${normalized}".`,
        projectID,
        occurredAt: now(),
      })
      return renamed
    },

    removeProject(projectID) {
      const project = fetchProjects(store).find((candidate) => candidate.id === projectID)
      if (project === undefined) {
        throw MuError.recordNotFound(`Project ${projectID} was not found.`)
      }
      const removed = { ...project, status: 'archived' as const, updatedAt: now() }
      upsertProject(store, removed)
      appendLedger(store, {
        type: 'project.archived',
        summary: `Archived project "${project.displayName}".`,
        projectID,
        occurredAt: now(),
      })
      return removed
    },

    // -----------------------------------------------------------------------
    // Agents
    // -----------------------------------------------------------------------

    createAgent(params) {
      const agent = createAgentIdentity({
        displayName: params.displayName,
        shortName: params.shortName,
        role: params.role,
        summary: params.summary,
        preferredEndpointID: params.preferredEndpointID,
        capabilityTags: params.capabilityTags,
        accentHex: params.accentHex ?? accentFor(params.displayName),
        createdAt: now(),
      })
      upsertAgent(store, agent)
      appendLedger(store, {
        type: 'agent.created',
        summary: `Registered agent "${agent.displayName}".`,
        actorID: agent.id,
        occurredAt: now(),
      })
      return agent
    },

    listAgents() {
      return fetchAgents(store)
    },

    // -----------------------------------------------------------------------
    // Endpoints
    // -----------------------------------------------------------------------

    registerEndpoint(params) {
      const endpointID = uuid()
      const endpoint = createRuntimeEndpoint({
        id: endpointID,
        runtimeTypeID: params.runtimeTypeID,
        displayName: params.displayName,
        adapterVersion: '1.0.0',
        runtimeVersion: params.runtimeVersion,
        location: params.location,
        provenance: 'vendor_cli',
        permissionModel: 'fine_grained',
        capabilities: new Set(['start', 'continue', 'cancel', 'stream_events']),
        status: 'discovered',
        guaranteeNote: 'Registered by the control plane.',
        lastProbedAt: now(),
        instanceIdentity: defaultInstanceIdentity(params, endpointID),
      })
      upsertEndpoint(store, endpoint)
      const registration = createRuntimeAdapterRegistration({
        endpointID: endpoint.id,
        manifest: {
          contractVersion: 1,
          adapterID: `mu.${endpoint.runtimeTypeID}`,
          provider: providerFor(endpoint),
          connectionKind: 'managed_runtime',
          controlMode: host.capabilities.controlMode,
          trustLevel: 'managed',
          observationFidelity: host.capabilities.observationFidelity,
          operations: [
            { operation: 'session.create', support: 'supported' },
            { operation: 'input.submit', support: 'supported' },
            { operation: 'events.observe', support: host.capabilities.supportsEventStream ? 'supported' : 'unsupported' },
            { operation: 'interrupt', support: host.capabilities.supportsInterrupt ? 'supported' : 'unsupported' },
            { operation: 'artifact.list', support: host.capabilities.supportsArtifacts ? 'supported' : 'unsupported' },
          ],
          instanceIdentity: endpoint.instanceIdentity!,
          notes: [],
        },
        probedAt: now(),
      })
      store.upsertRecord({
        kind: 'runtime_adapter_registration',
        id: registration.id,
        sortAt: registration.probedAt,
        value: registration,
      })
      appendLedger(store, {
        type: 'endpoint.registered',
        summary: `Registered runtime endpoint "${endpoint.displayName}".`,
        occurredAt: now(),
      })
      return endpoint
    },

    listEndpoints() {
      return fetchEndpoints(store)
    },

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------

    createTask(params) {
      const task = createTaskRecord({
        projectID: params.projectID,
        workspaceID: params.workspaceID,
        requestedByActorID: params.requestedByActorID,
        assignedActorID: params.assignedAgentIdentityID,
        title: params.title,
        objective: params.objective,
        successCriteria: params.successCriteria,
        constraints: params.constraints,
        repositoryPath: params.repositoryPath,
        status: 'ready',
        assignedAgentIdentityID: params.assignedAgentIdentityID,
        createdAt: now(),
        updatedAt: now(),
      })
      upsertTask(store, task)
      appendLedger(store, {
        type: 'task.created',
        summary: `Created task "${task.title}".`,
        projectID: params.projectID,
        workspaceID: params.workspaceID,
        taskID: task.id,
        actorID: params.requestedByActorID,
        occurredAt: now(),
      })
      return task
    },

    listTasks() {
      return fetchTasks(store)
    },

    fetchTask(taskID) {
      return fetchTask(store, taskID)
    },

    // -----------------------------------------------------------------------
    // Turn dispatch (the heart of the control plane)
    // -----------------------------------------------------------------------

    async *runTaskTurn(params) {
      let task = fetchTask(store, params.taskID)
      if (task === undefined) {
        throw MuError.recordNotFound(`Task ${params.taskID} was not found.`)
      }
      if (task.status === 'completed' || task.status === 'failed' || task.status === 'cancelled') {
        throw MuError.invalidTransition(`Task ${task.id} is already terminal (${task.status}).`)
      }
      if (params.text.trim() === '') {
        throw MuError.invalidTransition('runTaskTurn requires non-empty text.')
      }
      const projectID = task.projectID
      if (projectID === undefined) {
        throw MuError.invalidTransition(`Task ${task.id} has no project binding.`)
      }

      const autoTitle = summarizeFirstTaskMessage(params.text)
      if (autoTitle !== undefined && isPlaceholderTaskTitle(task.title)) {
        const titledAt = now()
        task = { ...task, title: autoTitle, updatedAt: titledAt }
        upsertTask(store, task)
        appendLedger(store, {
          type: 'task.auto_titled',
          summary: `Auto-titled task "${autoTitle}".`,
          projectID,
          workspaceID: task.workspaceID,
          taskID: task.id,
          occurredAt: titledAt,
          payload: { source: 'first_workspace_message' },
        })
      }

      const agent = task.assignedAgentIdentityID === undefined
        ? undefined
        : fetchAgent(store, task.assignedAgentIdentityID)
      const endpointID = params.endpointID
        ?? agent?.preferredEndpointID
        ?? fetchEndpoints(store).find((e) => e.status === 'active' || e.status === 'discovered')?.id
      if (endpointID === undefined) {
        throw MuError.capabilityMissing('No runtime endpoint is available for the task.')
      }
      const endpoint = fetchEndpoint(store, endpointID)
      if (endpoint === undefined) {
        throw MuError.recordNotFound(`Endpoint ${endpointID} was not found.`)
      }
      const scope = endpointScope(endpoint)
      if (params.reasoningEffort !== undefined && !['auto', 'low', 'medium', 'high', 'ultra'].includes(params.reasoningEffort)) {
        throw MuError.invalidTransition(`Unsupported reasoning effort '${String(params.reasoningEffort)}'.`)
      }
      const reasoningEffort = resolveReasoningEffort({
        requested: params.reasoningEffort,
        title: task.title,
        objective: task.objective,
        prompt: params.text,
        constraintCount: task.constraints.length,
      })

      // Serialize record preparation per endpoint; the host stream below also
      // holds the same queue until the turn reaches a terminal event.
      const prepared = await serializeOnEndpoint(endpointID, async () => {
        const nowT = now()

        // Fencing lease.
        const lease = createTaskLeaseRecord({
          projectID,
          taskID: task.id,
          agentActorID: task.assignedActorID ?? agent?.id ?? uuid(),
          endpointID,
          fencingToken: Math.floor(nowT.getTime() / 1000),
          state: 'active',
          issuedAt: nowT,
          expiresAt: new Date(nowT.getTime() + 60 * 60_000),
        })
        upsertTaskLease(store, lease)

        // Runtime session binding + immutable Context Pack + delivery receipt.
        const binding = createRuntimeSessionBinding({
          taskID: task.id,
          projectID,
          workspaceID: task.workspaceID,
          actorID: task.requestedByActorID,
          taskLeaseID: lease.id,
          endpointID,
          agentIdentityID: agent?.id,
          nativeSessionID: '',
          nativeAgentName: agent?.displayName ?? endpoint.displayName,
          workspacePath: task.repositoryPath,
          connectionMode: host.capabilities.mode,
          state: 'connecting',
          createdAt: nowT,
          updatedAt: nowT,
        })
        upsertRuntimeSessionBinding(store, binding)

        let pack: ProjectContextPackRecord
        if (params.contextPackID !== undefined) {
          const reused = fetchProjectContextPack(store, params.contextPackID)
          if (reused === undefined) {
            throw MuError.recordNotFound(`Context Pack ${params.contextPackID} was not found.`)
          }
          const targetWorkspaceID = task.workspaceID ?? projectID
          if (reused.projectID !== projectID || reused.workspaceID !== targetWorkspaceID) {
            throw MuError.invalidTransition(
              'A Context Pack can only be delivered within the same project and workspace.',
            )
          }
          pack = reused
        } else {
          pack = buildProjectContextPack(store, {
            projectID,
            taskID: task.id,
            workspaceID: task.workspaceID ?? projectID,
            objective: task.objective,
            endpointID,
            bindingID: binding.id,
            actorID: task.requestedByActorID ?? agent?.id ?? uuid(),
            taskLeaseID: lease.id,
            leaseFencingToken: lease.fencingToken,
            constraints: task.constraints,
            includedContextRecordIDs: params.contextRecordIDs,
            createdAt: nowT,
          })
          insertProjectContextPack(store, pack)
        }

        const run = createRunRecord({
          taskID: task.id,
          projectID,
          workspaceID: task.workspaceID,
          actorID: task.requestedByActorID,
          taskLeaseID: lease.id,
          contextPackID: pack.id,
          endpointID,
          reasoningEffort,
          actorName: agent?.displayName ?? endpoint.displayName,
          purpose: 'execution',
          state: 'starting',
          agentIdentityID: agent?.id,
          createdAt: nowT,
          updatedAt: nowT,
        })
        upsertRun(store, run)

        createDeliveryReceipt(store, {
          projectID,
          taskID: task.id,
          contextPackID: pack.id,
          runtimeBindingID: binding.id,
          runID: run.id,
          endpointID,
          actorID: task.requestedByActorID ?? agent?.id ?? uuid(),
          workspaceID: task.workspaceID ?? projectID,
          taskLeaseID: lease.id,
          leaseFencingToken: lease.fencingToken,
          contextRevision: pack.contextRevision ?? '1',
          policyRevision: pack.policyRevision ?? '1',
          packContentSHA256: pack.contentSHA256,
          status: 'delivered',
          completedAt: nowT,
        })

        const userChat = createChatEntry({
          taskID: task.id,
          agentIdentityID: agent?.id,
          targetAgentIdentityID: agent?.id,
          targetEndpointID: endpointID,
          runID: run.id,
          runtimeSessionBindingID: binding.id,
          authorKind: 'user',
          authorName: 'User',
          text: params.text,
          routedText: params.text,
          deliveryState: 'routing',
          createdAt: nowT,
        })
        insertChatEntry(store, userChat)

        const runningTask: TaskRecord = { ...task, status: 'running', updatedAt: nowT }
        upsertTask(store, runningTask)

        appendLedger(store, {
          type: 'task.run_started',
          summary: `Started execution of "${task.title}" on ${endpoint.displayName}.`,
          projectID,
          workspaceID: task.workspaceID,
          taskID: task.id,
          runID: run.id,
          actorID: task.requestedByActorID,
          occurredAt: nowT,
        })

        emit({ kind: 'run_created', run, binding, pack })
        emit({ kind: 'chat_entry', chatEntry: userChat })

        return { runningTask, run, binding, pack, lease }
      })

      const { runningTask, run, binding, pack, lease } = prepared

      // Stream the turn through the harness, persisting as we go.
      const input: HarnessTurnInput = {
        provider: providerFor(endpoint),
        task,
        contextPack: pack,
        text: params.text,
        sessionID: params.sessionID,
        resumeSessionID: params.resumeSessionID,
        promptOverride: params.promptOverride,
        reasoningEffort,
      }
      upsertRuntimeSessionBinding(store, { ...binding, state: 'working', updatedAt: now() })
      upsertRun(store, { ...run, state: 'active', updatedAt: now() })

      let output = ''
      let sessionID = ''
      let terminalEvent: HarnessTurnEvent | undefined

      for await (const event of streamOnEndpoint(endpointID, () => host.submit(scope, input))) {
        switch (event.kind) {
          case 'session_started':
            sessionID = event.sessionID
            upsertRuntimeSessionBinding(store, {
              ...binding,
              nativeSessionID: event.sessionID,
              state: 'working',
              lastActivitySummary: 'Agent session started.',
              updatedAt: now(),
            })
            break
          case 'visible_text':
            // Visible-text events are deltas; keep accumulating for the
            // streamed chat. The terminal result below is authoritative.
            output += event.text
            break
          case 'pending_approval':
            for (const approval of event.approvals) {
              const interaction = createRuntimeInteractionRequest({
                taskID: task.id,
                bindingID: binding.id,
                endpointID,
                nativeSessionID: sessionID,
                nativeRequestID: approval.requestID,
                kind: 'approval',
                title: `Approval: ${approval.command}`,
                detail: approval.reason,
                payload: { requestID: approval.requestID },
                state: 'pending',
                createdAt: now(),
              })
              upsertRuntimeInteraction(store, interaction)
              const projectApproval = createProjectApprovalRecord({
                projectID,
                taskID: task.id,
                runtimeInteractionID: interaction.id,
                requestedByActorID: task.requestedByActorID ?? uuid(),
                scope: approval.command,
                decision: 'pending',
                createdAt: now(),
              })
              upsertProjectApproval(store, projectApproval)
              appendLedger(store, {
                type: 'task.approval_requested',
                summary: `Agent requested approval for ${approval.command}.`,
                projectID,
                taskID: task.id,
                runID: run.id,
                approvalID: projectApproval.id,
                occurredAt: now(),
              })
            }
            break
          default:
            break
        }
        terminalEvent = event
        yield event
      }

      // ---------------------------------------------------------------------
      // Terminal: persist final run/task/binding state, chat, artifacts.
      // ---------------------------------------------------------------------
      const nowT = now()

      if (sessionID !== '') {
        const artifacts = await host.listArtifacts(scope, sessionID)
        for (const artifact of artifacts) {
          upsertRuntimeArtifact(
            store,
            createRuntimeArtifactRecord({
              taskID: task.id,
              bindingID: binding.id,
              endpointID,
              nativeSessionID: sessionID,
              relativePath: artifact.relativePath,
              name: artifact.name,
              kind: artifact.kind,
              byteCount: artifact.byteCount ?? 0,
              modifiedAt: artifact.modifiedAt ?? nowT,
              observedAt: nowT,
            }),
          )
        }
      }

      const agentChat = createChatEntry({
        taskID: task.id,
        agentIdentityID: agent?.id,
        runID: run.id,
        runtimeSessionBindingID: binding.id,
        authorKind: 'agent',
        authorName: agent?.displayName ?? endpoint.displayName,
        text: output,
        deliveryState: 'delivered',
        createdAt: nowT,
      })
      insertChatEntry(store, agentChat)
      emit({ kind: 'chat_entry', chatEntry: agentChat })

      // Terminal states from the last harness event.
      let runState: RunRecord['state'] = 'completed'
      let taskStatus: TaskRecord['status'] = 'completed'
      let bindingState: RuntimeSessionBinding['state'] = 'completed'
      let errorMessage: string | undefined
      if (terminalEvent?.kind === 'failed') {
        runState = 'failed'
        taskStatus = 'failed'
        bindingState = 'failed'
        errorMessage = terminalEvent.errorMessage
      } else if (terminalEvent?.kind === 'cancelled') {
        runState = 'cancelled'
        taskStatus = 'cancelled'
        bindingState = 'disconnected'
        errorMessage = 'Interrupted in Mu.'
      } else if (terminalEvent?.kind === 'completed' && terminalEvent.result.status === 'failed') {
        runState = 'failed'
        taskStatus = 'failed'
        bindingState = 'failed'
        errorMessage = terminalEvent.result.errorMessage
      } else if (terminalEvent?.kind === 'completed' && terminalEvent.result.status === 'cancelled') {
        runState = 'cancelled'
        taskStatus = 'cancelled'
        bindingState = 'disconnected'
        errorMessage = 'Interrupted in Mu.'
      } else if (terminalEvent?.kind === 'completed' && terminalEvent.result.status === 'pending_approval') {
        runState = 'blocked'
        taskStatus = 'blocked'
        bindingState = 'awaiting_approval'
        errorMessage = 'Awaiting approval.'
      }
      // The harness result carries the authoritative full output; prefer it
      // over the accumulated deltas (which may include replacement events).
      if (terminalEvent?.kind === 'completed') {
        output = terminalEvent.result.output
      }

      upsertRun(store, {
        ...run,
        state: runState,
        nativeThreadID: sessionID === '' ? undefined : sessionID,
        nativeTurnID: sessionID === '' ? undefined : sessionID,
        nativeOutput: output,
        updatedAt: nowT,
      })
      upsertRuntimeSessionBinding(store, {
        ...binding,
        nativeSessionID: sessionID,
        state: bindingState,
        lastSyncedMessageCount: 1,
        lastActivitySummary: output.trim() === '' ? 'Turn completed.' : output.trim().slice(0, 140),
        lastError: errorMessage,
        updatedAt: nowT,
      })
      upsertTask(store, { ...runningTask, status: taskStatus, updatedAt: nowT })
      upsertTaskLease(store, { ...lease, state: 'released' })

      appendLedger(store, {
        type: taskStatus === 'completed' ? 'task.run_completed'
          : taskStatus === 'failed' ? 'task.run_failed'
            : taskStatus === 'blocked' ? 'task.run_blocked'
              : 'task.run_cancelled',
        summary: taskStatus === 'completed'
          ? `Execution of "${task.title}" completed.`
          : taskStatus === 'failed'
            ? `Execution of "${task.title}" failed.`
            : taskStatus === 'blocked'
              ? `Execution of "${task.title}" is blocked awaiting approval.`
              : `Execution of "${task.title}" was cancelled.`,
        projectID,
        workspaceID: task.workspaceID,
        taskID: task.id,
        runID: run.id,
        actorID: task.requestedByActorID,
        payload: errorMessage === undefined ? undefined : { errorMessage },
        occurredAt: nowT,
      })
      yield { kind: 'chat_entry', chatEntry: agentChat }
    },

    async interruptRun(runID) {
      const run = fetchRun(store, runID)
      if (run === undefined) {
        throw MuError.recordNotFound(`Run ${runID} was not found.`)
      }
      if (run.state === 'completed' || run.state === 'failed' || run.state === 'cancelled') {
        throw MuError.invalidTransition(`Run ${runID} is already terminal (${run.state}).`)
      }
      const endpoint = fetchEndpoint(store, run.endpointID)
      if (endpoint === undefined) {
        throw MuError.recordNotFound(`Endpoint ${run.endpointID} was not found.`)
      }
      await host.interrupt(endpointScope(endpoint), run.nativeThreadID ?? run.id)
      const updated: RunRecord = { ...run, state: 'cancelled', updatedAt: now() }
      upsertRun(store, updated)
      appendLedger(store, {
        type: 'task.run_cancelled',
        summary: 'Run interrupted by the control plane.',
        taskID: run.taskID,
        runID: run.id,
        occurredAt: now(),
      })
    },

    // -----------------------------------------------------------------------
    // Context import / review / conflicts
    // -----------------------------------------------------------------------

    importContextRecord(params) {
      const nowT = now()
      const source = createContextSourceRecord({
        projectID: params.projectID,
        sourceType: 'runtime_session',
        sourceActorID: params.sourceActorID,
        sourcePrincipalID: params.sourcePrincipalID,
        runtimeEndpointID: params.runtimeEndpointID,
        runtimeSessionID: params.runtimeSessionID,
        externalRef: params.externalRef,
        sourceChecksum: sha256Hex(params.text),
        importedAt: nowT,
      })
      upsertContextSource(store, source)

      const record = createContextRecord({
        projectID: params.projectID,
        sourceID: source.id,
        externalID: params.externalRef,
        kind: params.kind,
        subject: params.subject,
        value: pcvString(params.text),
        status: 'candidate',
        scope: { taskID: params.taskID },
        confidence: params.confidence,
        createdByActorID: params.sourceActorID,
        createdAt: nowT,
      })
      upsertContextRecord(store, record)

      const subject = record.subject ?? 'untitled'
      // Conflict detection: same subject, accepted, overlapping task scope.
      const overlapping = fetchContextRecords(store, params.projectID).filter(
        (r) => r.status === 'accepted'
          && r.subject === subject
          && r.id !== record.id
          && (params.taskID === undefined || r.scope.taskID === params.taskID),
      )
      if (overlapping.length > 0) {
        const conflict = createContextConflictRecord({
          id: stableConflictID(params.projectID, subject, [record.id, ...overlapping.map((r) => r.id)]),
          projectID: params.projectID,
          subject,
          recordIDs: [record.id, ...overlapping.map((r) => r.id)],
          conflictType: 'value',
          status: 'unresolved',
          createdAt: nowT,
        })
        upsertContextConflict(store, conflict)
        appendLedger(store, {
          type: 'context.conflict_detected',
          summary: `Detected a context conflict on "${record.subject}".`,
          projectID: params.projectID,
          taskID: params.taskID,
          actorID: params.sourceActorID,
          occurredAt: nowT,
        })
      }

      appendLedger(store, {
        type: 'context.imported',
        summary: `Imported context record "${record.subject}" (${record.kind}).`,
        projectID: params.projectID,
        taskID: params.taskID,
        actorID: params.sourceActorID,
        occurredAt: nowT,
      })
      return record
    },

    reviewContextRecord(params) {
      const record = transitionContextRecordStatus(
        store,
        params.recordID,
        params.decision,
        params.actorID,
        now(),
      )
      appendLedger(store, {
        type: 'context.reviewed',
        summary: `Context record "${record.subject}" reviewed as ${record.status}.`,
        projectID: record.projectID,
        taskID: record.scope.taskID,
        actorID: params.actorID,
        occurredAt: now(),
      })
      return record
    },

    listContextRecords(projectID) {
      return fetchContextRecords(store, projectID)
    },

    buildContextPack(params) {
      const pack = buildProjectContextPack(store, {
        projectID: params.projectID,
        taskID: params.taskID,
        workspaceID: params.workspaceID,
        objective: params.objective,
        endpointID: params.endpointID,
        bindingID: uuid(),
        actorID: params.actorID,
        principalID: params.principalID,
        includedContextRecordIDs: params.contextRecordIDs,
        createdAt: now(),
      })
      insertProjectContextPack(store, pack)
      return pack
    },

    resolveConflict(params) {
      const conflict = fetchContextConflicts(store).find((c) => c.id === params.conflictID)
      if (conflict === undefined) {
        throw MuError.recordNotFound(`Context conflict ${params.conflictID} was not found.`)
      }
      if (conflict.status !== 'unresolved') {
        throw MuError.invalidTransition(`Conflict ${conflict.id} is already resolved.`)
      }
      for (const recordID of conflict.recordIDs) {
        const record = fetchContextRecord(store, recordID)
        if (record === undefined) continue
        if (params.acceptedRecordIDs.includes(recordID)) {
          transitionContextRecordStatus(store, recordID, 'accepted', params.actorID, now())
        } else if (record.status === 'accepted') {
          // Accepted records are superseded by the resolution.
          transitionContextRecordStatus(store, recordID, 'superseded', params.actorID, now())
        } else {
          // Candidates never accepted are rejected outright.
          transitionContextRecordStatus(store, recordID, 'rejected', params.actorID, now())
        }
      }
      const resolved: ContextConflictRecordLike = {
        ...conflict,
        status: 'resolved',
        resolvedByActorID: params.actorID,
        acceptedRecordIDs: params.acceptedRecordIDs,
        resolutionNote: params.note,
        resolvedAt: now(),
        revision: conflict.revision + 1,
      }
      upsertContextConflict(store, resolved)
      appendLedger(store, {
        type: 'context.conflict_resolved',
        summary: `Resolved conflict on "${conflict.subject}".`,
        projectID: conflict.projectID,
        actorID: params.actorID,
        occurredAt: now(),
      })
      return resolved
    },

    // -----------------------------------------------------------------------
    // Approvals & reviews
    // -----------------------------------------------------------------------

    requestApproval(params) {
      const approval = createProjectApprovalRecord({
        projectID: params.projectID,
        taskID: params.taskID,
        requestedByActorID: params.requestedByActorID,
        scope: params.scope,
        decision: 'pending',
        createdAt: now(),
      })
      upsertProjectApproval(store, approval)
      appendLedger(store, {
        type: 'task.approval_requested',
        summary: `Approval requested for ${params.scope}.`,
        projectID: params.projectID,
        taskID: params.taskID,
        approvalID: approval.id,
        actorID: params.requestedByActorID,
        occurredAt: now(),
      })
      return approval
    },

    resolveApproval(params) {
      const approval = fetchProjectApprovals(store).find((a) => a.id === params.approvalID)
      if (approval === undefined) {
        throw MuError.recordNotFound(`Approval ${params.approvalID} was not found.`)
      }
      if (approval.decision !== 'pending') {
        throw MuError.invalidTransition(`Approval ${approval.id} is already ${approval.decision}.`)
      }
      const resolved: ProjectApprovalRecord = {
        ...approval,
        decision: params.decision,
        approverActorID: params.approverActorID,
        reason: params.reason,
        resolvedAt: now(),
      }
      upsertProjectApproval(store, resolved)
      if (approval.runtimeInteractionID !== undefined) {
        const interaction = fetchRuntimeInteractions(store).find(
          (i) => i.id === approval.runtimeInteractionID,
        )
        if (interaction !== undefined) {
          upsertRuntimeInteraction(store, {
            ...interaction,
            state: params.decision === 'granted' ? 'approved' : 'denied',
            resolvedAt: now(),
          })
        }
      }
      appendLedger(store, {
        type: 'task.approval_resolved',
        summary: `Approval for ${approval.scope} ${params.decision}.`,
        projectID: approval.projectID,
        taskID: approval.taskID,
        approvalID: approval.id,
        actorID: params.approverActorID,
        occurredAt: now(),
      })
      return resolved
    },

    submitReview(params) {
      const review = createProjectReviewRecord({
        projectID: params.projectID,
        taskID: params.taskID,
        reviewerActorID: params.reviewerActorID,
        verdict: params.verdict,
        findings: params.findings,
        createdAt: now(),
        resolvedAt: now(),
      })
      upsertProjectReview(store, review)
      appendLedger(store, {
        type: 'task.review_submitted',
        summary: `Review verdict: ${params.verdict}.`,
        projectID: params.projectID,
        taskID: params.taskID,
        reviewID: review.id,
        actorID: params.reviewerActorID,
        occurredAt: now(),
      })
      return review
    },

    // -----------------------------------------------------------------------
    // Handoffs
    // -----------------------------------------------------------------------

    proposeHandoff(params) {
      const checkpoint = {
        id: uuid() as UUID,
        taskID: params.taskID,
        sourceEndpointID: params.sourceEndpointID,
        contentHash: sha256Hex(`handoff:${params.taskID}:${now().toISOString()}`),
        content: createCheckpointContent({
          taskID: params.taskID,
          sourceEndpointID: params.sourceEndpointID,
          objective: 'Handoff checkpoint',
          successCriteria: [],
          pendingSteps: [],
          constraints: [],
          repository: {
            path: '',
            isGitRepository: false,
            branch: '',
            baseCommit: '',
            headCommit: '',
            isDirty: false,
            untrackedFiles: [],
          },
          createdAt: now(),
        }),
        createdAt: now(),
      }
      insertCheckpoint(store, checkpoint)
      const handoff = createHandoffRecord({
        taskID: params.taskID,
        checkpointID: checkpoint.id,
        sourceEndpointID: params.sourceEndpointID,
        receiverEndpointID: params.receiverEndpointID,
        status: 'proposed',
        validationMessage: params.validationMessage,
        createdAt: now(),
      })
      upsertHandoff(store, handoff)
      appendLedger(store, {
        type: 'task.handoff_proposed',
        summary: 'Handoff proposed between runtime endpoints.',
        taskID: params.taskID,
        occurredAt: now(),
      })
      return handoff
    },

    resolveHandoff(params) {
      const handoff = fetchHandoffs(store).find((h) => h.id === params.handoffID)
      if (handoff === undefined) {
        throw MuError.recordNotFound(`Handoff ${params.handoffID} was not found.`)
      }
      if (handoff.status !== 'proposed' && handoff.status !== 'validating') {
        throw MuError.invalidTransition(`Handoff ${handoff.id} is already ${handoff.status}.`)
      }
      const resolved: HandoffRecord = {
        ...handoff,
        status: params.accepted ? 'accepted' : 'rejected',
        validationMessage: params.validationMessage,
        rejectionReason: params.rejectionReason,
        resolvedAt: now(),
      }
      upsertHandoff(store, resolved)
      appendLedger(store, {
        type: 'task.handoff_resolved',
        summary: `Handoff ${params.accepted ? 'accepted' : 'rejected'}.`,
        taskID: handoff.taskID,
        occurredAt: now(),
      })
      return resolved
    },

    listHandoffs(taskID) {
      return taskID === undefined ? fetchHandoffs(store) : fetchHandoffs(store, taskID)
    },

    // -----------------------------------------------------------------------
    // Ledger & queries
    // -----------------------------------------------------------------------

    fetchLedger(taskID, limit) {
      return fetchLedger(store, taskID, limit)
    },

    listRuns(taskID) {
      return fetchRuns(store, taskID)
    },

    listChatEntries(taskID) {
      return fetchChatEntries(store, taskID)
    },

    listSessionBindings(taskID) {
      return fetchRuntimeSessionBindings(store, taskID)
    },

    listRuntimeArtifacts(taskID) {
      return fetchRuntimeArtifacts(store, taskID)
    },

    async discoverHistory(endpointID, workspacePath) {
      if (host.discoverHistory === undefined) return []
      const endpoint = fetchEndpoint(store, endpointID)
      if (endpoint === undefined) {
        throw MuError.recordNotFound(`Endpoint ${endpointID} was not found.`)
      }
      return host.discoverHistory(endpointScope(endpoint), workspacePath)
    },

    async hydrateHistory(endpointID, candidate) {
      if (host.hydrateHistory === undefined) {
        throw MuError.capabilityMissing('This host does not support history hydration.')
      }
      const endpoint = fetchEndpoint(store, endpointID)
      if (endpoint === undefined) {
        throw MuError.recordNotFound(`Endpoint ${endpointID} was not found.`)
      }
      return host.hydrateHistory(endpointScope(endpoint), candidate)
    },

    async warmEndpoints() {
      if (host.warmEndpoint === undefined) return
      const endpoints = fetchEndpoints(store).filter((endpoint) =>
        endpoint.status === 'active' || endpoint.status === 'discovered'
      )
      await Promise.all(endpoints.map(async (endpoint) => {
        try {
          await host.warmEndpoint!(endpointScope(endpoint))
        } catch {
          // Warm-up is intentionally best effort. The first turn still has a
          // correct start path when an endpoint was offline during launch.
        }
      }))
    },

    async probeEndpoints() {
      const outcomes: ProbeOutcome[] = []
      for (const endpoint of fetchEndpoints(store)) {
        const result = await host.probe(endpointScope(endpoint))
        const probedAt = now()
        const updated: RuntimeEndpoint = {
          ...endpoint,
          status: result.ok ? 'active' : 'offline',
          lastProbedAt: probedAt,
        }
        upsertEndpoint(store, updated)
        appendLedger(store, {
          type: 'endpoint.probed',
          summary: result.ok
            ? `${endpoint.displayName} is active (${result.message}).`
            : `${endpoint.displayName} is offline (${result.message}).`,
          payload: { ok: String(result.ok), latencyMilliseconds: String(result.latencyMilliseconds) },
          occurredAt: probedAt,
        })
        outcomes.push({ endpointID: endpoint.id, ok: result.ok, message: result.message })
      }
      return outcomes
    },

    close() {
      // Release long-lived host processes (codex app-server, SSE streams)
      // before closing the store, so the process can exit cleanly.
      host.stop?.()
      store.close()
    },
  }
}

// ---------------------------------------------------------------------------
// Small local helpers
// ---------------------------------------------------------------------------

function isPlaceholderTaskTitle(title: string): boolean {
  return ['new task', 'untitled task', 'new workspace task'].includes(title.trim().toLowerCase())
}

function summarizeFirstTaskMessage(text: string): string | undefined {
  const words = text.trim().split(/\s+/u)
  while (words[0]?.startsWith('@') === true) words.shift()
  if (words[0]?.toLowerCase() === 'code') words.shift()
  const candidate = words.join(' ').split(/[.!?\n]/u, 1)[0]?.trim()
  if (candidate === undefined || candidate === '') return undefined
  return candidate.length > 72 ? `${candidate.slice(0, 71)}…` : candidate
}

/**
 * Instance identity for a registered endpoint. Callers can override any
 * field (e.g. bootstrap supplies the real executable path); the defaults
 * distinguish endpoints without flattening them into a bare provider name.
 */
function defaultInstanceIdentity(
  params: {
    runtimeTypeID: string
    displayName: string
    location: RuntimeEndpoint['location']
    instanceIdentity?: Partial<AgentRuntimeInstanceIdentity>
  },
  endpointID: UUID,
): AgentRuntimeInstanceIdentity {
  const base: AgentRuntimeInstanceIdentity = {
    provider: providerForRuntimeTypeID(params.runtimeTypeID),
    surfaceKind: params.location === 'local' ? 'terminal_cli' : 'remote_service',
    identityBasis: 'installation',
    stableInstanceKey: `${params.runtimeTypeID}:${endpointID}`,
    instanceLabel: params.displayName,
  }
  return { ...base, ...params.instanceIdentity }
}

function providerForRuntimeTypeID(runtimeTypeID: string): { rawValue: string } {
  const normalized = runtimeTypeID.toLowerCase()
  if (normalized.includes('codex')) return { rawValue: 'codex' }
  if (normalized.includes('claude')) return { rawValue: 'claude_code' }
  return { rawValue: normalized.split('/')[0] ?? normalized }
}

function accentFor(name: string): string {
  let hash = 0
  for (const char of name) hash = (hash * 31 + char.charCodeAt(0)) | 0
  const palette = ['#5B8DEF', '#8A63D2', '#E08A3C', '#3C9E7A', '#C2495A', '#4A90A4']
  return palette[Math.abs(hash) % palette.length]!
}
