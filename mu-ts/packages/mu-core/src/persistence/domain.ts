import type { UUID } from '../identity.ts'
import type {
  AgentIdentity,
  ChatEntry,
  CheckpointRecord,
  HandoffRecord,
  RegistryTombstone,
  RunRecord,
  RuntimeArtifactRecord,
  RuntimeEndpoint,
  RuntimeInteractionRequest,
  RuntimeSessionBinding,
  TaskRecord,
} from '../models.ts'
import type {
  DelegationRecord,
  ProjectActorRecord,
  ProjectApprovalRecord,
  ProjectArtifactRecord,
  ProjectContextPackRecord,
  ProjectMembershipRecord,
  PrincipalRecord,
  ProjectRecord,
  ProjectReviewRecord,
  ProjectWorkspaceRecord,
  TaskLeaseRecord,
  TaskProjectLink,
} from '../project-kernel/index.ts'
import type { RuntimeAdapterRegistration } from '../runtime-gateway/manifest.ts'
import type { SQLiteStore } from './store.ts'

/**
 * Domain-specific record APIs, mirroring the Swift SQLiteStore public methods.
 * All of these use the generic `records` table with the Swift kind strings.
 */

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

export function fetchTasks(store: SQLiteStore): TaskRecord[] {
  return store.fetchRecords<TaskRecord>('task')
}

export function fetchTask(store: SQLiteStore, id: UUID): TaskRecord | undefined {
  return store.fetchRecord<TaskRecord>('task', id)
}

export function upsertTask(store: SQLiteStore, task: TaskRecord): void {
  store.upsertRecord({ kind: 'task', id: task.id, taskID: task.id, sortAt: task.updatedAt, value: task })
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

export function fetchRuns(store: SQLiteStore, taskID?: UUID): RunRecord[] {
  return taskID === undefined
    ? store.fetchRecords<RunRecord>('run')
    : store.fetchRecordsForTask<RunRecord>('run', taskID)
}

export function fetchRun(store: SQLiteStore, id: UUID): RunRecord | undefined {
  return store.fetchRecord<RunRecord>('run', id)
}

export function upsertRun(store: SQLiteStore, run: RunRecord): void {
  store.upsertRecord({ kind: 'run', id: run.id, taskID: run.taskID, sortAt: run.updatedAt, value: run })
}

// ---------------------------------------------------------------------------
// Runtime endpoints and agents
// ---------------------------------------------------------------------------

export function fetchEndpoints(store: SQLiteStore): RuntimeEndpoint[] {
  return store.fetchRecords<RuntimeEndpoint>('endpoint').map(restoreEndpointSets)
}

export function fetchRegisteredEndpoints(store: SQLiteStore): RuntimeEndpoint[] {
  const removedIDs = new Set(
    fetchRegistryTombstones(store)
      .filter((tombstone) => tombstone.entityKind === 'runtime_endpoint')
      .map((tombstone) => tombstone.id),
  )
  return fetchEndpoints(store).filter((endpoint) => !removedIDs.has(endpoint.id))
}

export function fetchEndpoint(store: SQLiteStore, id: UUID): RuntimeEndpoint | undefined {
  const endpoint = store.fetchRecord<RuntimeEndpoint>('endpoint', id)
  return endpoint === undefined ? undefined : restoreEndpointSets(endpoint)
}

export function fetchRegisteredEndpoint(store: SQLiteStore, id: UUID): RuntimeEndpoint | undefined {
  return fetchRegisteredEndpoints(store).find((endpoint) => endpoint.id === id)
}

/** Swift encodes Set fields as JSON arrays; restore them on decode. */
function restoreEndpointSets(endpoint: RuntimeEndpoint): RuntimeEndpoint {
  return {
    ...endpoint,
    capabilities: new Set(endpoint.capabilities),
  }
}

export function upsertEndpoint(store: SQLiteStore, endpoint: RuntimeEndpoint): void {
  store.upsertRecord({
    kind: 'endpoint',
    id: endpoint.id,
    taskID: undefined,
    sortAt: endpoint.lastProbedAt,
    value: endpoint,
  })
}

export function deleteEndpoint(store: SQLiteStore, id: UUID): void {
  store.deleteRecord('endpoint', id)
}

export function fetchAgents(store: SQLiteStore): AgentIdentity[] {
  return store.fetchRecords<AgentIdentity>('agent_identity')
}

export function fetchAgent(store: SQLiteStore, id: UUID): AgentIdentity | undefined {
  return store.fetchRecord<AgentIdentity>('agent_identity', id)
}

export function upsertAgent(store: SQLiteStore, agent: AgentIdentity): void {
  store.upsertRecord({
    kind: 'agent_identity',
    id: agent.id,
    taskID: undefined,
    sortAt: agent.createdAt,
    value: agent,
  })
}

export function deleteAgent(store: SQLiteStore, id: UUID): void {
  store.deleteRecord('agent_identity', id)
}

export function fetchRegistryTombstones(store: SQLiteStore): RegistryTombstone[] {
  return store.fetchRecords<RegistryTombstone>('registry_tombstone')
}

export function upsertRegistryTombstone(store: SQLiteStore, tombstone: RegistryTombstone): void {
  store.upsertRecord({
    kind: 'registry_tombstone',
    id: tombstone.id,
    taskID: undefined,
    sortAt: tombstone.deletedAt,
    value: tombstone,
  })
}

export function fetchRuntimeAdapterRegistrations(store: SQLiteStore): RuntimeAdapterRegistration[] {
  return store.fetchRecords<RuntimeAdapterRegistration>('runtime_adapter_registration')
}

export function upsertRuntimeAdapterRegistration(
  store: SQLiteStore,
  registration: RuntimeAdapterRegistration,
): void {
  store.upsertRecord({
    kind: 'runtime_adapter_registration',
    id: registration.id,
    taskID: undefined,
    sortAt: registration.probedAt,
    value: registration,
  })
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

export function fetchChatEntries(store: SQLiteStore, taskID?: UUID): ChatEntry[] {
  return taskID === undefined
    ? store.fetchRecords<ChatEntry>('chat_entry')
    : store.fetchRecordsForTask<ChatEntry>('chat_entry', taskID)
}

export function fetchChatEntry(store: SQLiteStore, id: UUID): ChatEntry | undefined {
  return store.fetchRecord<ChatEntry>('chat_entry', id)
}

export function insertChatEntry(store: SQLiteStore, entry: ChatEntry): void {
  store.insertImmutableRecord({
    kind: 'chat_entry',
    id: entry.id,
    taskID: entry.taskID,
    sortAt: entry.createdAt,
    value: entry,
  })
}

export function upsertChatEntry(store: SQLiteStore, entry: ChatEntry): void {
  store.upsertRecord({
    kind: 'chat_entry',
    id: entry.id,
    taskID: entry.taskID,
    sortAt: entry.updatedAt ?? entry.createdAt,
    value: entry,
  })
}

export function deleteChatEntry(store: SQLiteStore, id: UUID): void {
  store.deleteRecord('chat_entry', id)
}

// ---------------------------------------------------------------------------
// Runtime session bindings, interactions, artifacts
// ---------------------------------------------------------------------------

export function fetchRuntimeSessionBindings(store: SQLiteStore, taskID?: UUID): RuntimeSessionBinding[] {
  return taskID === undefined
    ? store.fetchRecords<RuntimeSessionBinding>('runtime_session_binding')
    : store.fetchRecordsForTask<RuntimeSessionBinding>('runtime_session_binding', taskID)
}

export function fetchRuntimeSessionBinding(
  store: SQLiteStore,
  id: UUID,
): RuntimeSessionBinding | undefined {
  return store.fetchRecord<RuntimeSessionBinding>('runtime_session_binding', id)
}

export function upsertRuntimeSessionBinding(
  store: SQLiteStore,
  binding: RuntimeSessionBinding,
): void {
  store.upsertRecord({
    kind: 'runtime_session_binding',
    id: binding.id,
    taskID: binding.taskID,
    sortAt: binding.updatedAt,
    value: binding,
  })
}

export function fetchRuntimeInteractions(
  store: SQLiteStore,
  taskID?: UUID,
): RuntimeInteractionRequest[] {
  return taskID === undefined
    ? store.fetchRecords<RuntimeInteractionRequest>('runtime_interaction')
    : store.fetchRecordsForTask<RuntimeInteractionRequest>('runtime_interaction', taskID)
}

export function fetchRuntimeInteraction(
  store: SQLiteStore,
  id: UUID,
): RuntimeInteractionRequest | undefined {
  return store.fetchRecord<RuntimeInteractionRequest>('runtime_interaction', id)
}

export function upsertRuntimeInteraction(
  store: SQLiteStore,
  request: RuntimeInteractionRequest,
): void {
  store.upsertRecord({
    kind: 'runtime_interaction',
    id: request.id,
    taskID: request.taskID,
    sortAt: request.createdAt,
    value: request,
  })
}

export function fetchRuntimeArtifacts(store: SQLiteStore, taskID?: UUID): RuntimeArtifactRecord[] {
  return taskID === undefined
    ? store.fetchRecords<RuntimeArtifactRecord>('runtime_artifact')
    : store.fetchRecordsForTask<RuntimeArtifactRecord>('runtime_artifact', taskID)
}

export function upsertRuntimeArtifact(store: SQLiteStore, artifact: RuntimeArtifactRecord): void {
  store.upsertRecord({
    kind: 'runtime_artifact',
    id: artifact.id,
    taskID: artifact.taskID,
    sortAt: artifact.observedAt,
    value: artifact,
  })
}

// ---------------------------------------------------------------------------
// Checkpoints and handoffs
// ---------------------------------------------------------------------------

export function fetchCheckpoints(store: SQLiteStore, taskID?: UUID): CheckpointRecord[] {
  return taskID === undefined
    ? store.fetchRecords<CheckpointRecord>('checkpoint')
    : store.fetchRecordsForTask<CheckpointRecord>('checkpoint', taskID)
}

export function fetchCheckpoint(store: SQLiteStore, id: UUID): CheckpointRecord | undefined {
  return store.fetchRecord<CheckpointRecord>('checkpoint', id)
}

export function insertCheckpoint(store: SQLiteStore, checkpoint: CheckpointRecord): void {
  store.insertImmutableRecord({
    kind: 'checkpoint',
    id: checkpoint.id,
    taskID: checkpoint.taskID,
    sortAt: checkpoint.createdAt,
    value: checkpoint,
  })
}

export function fetchHandoffs(store: SQLiteStore, taskID?: UUID): HandoffRecord[] {
  return taskID === undefined
    ? store.fetchRecords<HandoffRecord>('handoff')
    : store.fetchRecordsForTask<HandoffRecord>('handoff', taskID)
}

export function upsertHandoff(store: SQLiteStore, handoff: HandoffRecord): void {
  store.upsertRecord({
    kind: 'handoff',
    id: handoff.id,
    taskID: handoff.taskID,
    sortAt: handoff.resolvedAt ?? handoff.createdAt,
    value: handoff,
  })
}

// ---------------------------------------------------------------------------
// Project Kernel records
// ---------------------------------------------------------------------------

const PK = {
  project: 'project',
  principal: 'principal',
  projectActor: 'project_actor',
  membership: 'project_membership',
  delegation: 'project_delegation',
  workspace: 'project_workspace',
  taskLink: 'task_project_link',
  lease: 'task_lease',
  artifact: 'project_artifact',
  review: 'project_review',
  approval: 'project_approval',
  contextPack: 'project_context_pack',
} as const

export function fetchProjects(store: SQLiteStore): ProjectRecord[] {
  return store.fetchRecords<ProjectRecord>(PK.project)
}

export function fetchProject(store: SQLiteStore, id: UUID): ProjectRecord | undefined {
  return store.fetchRecord<ProjectRecord>(PK.project, id)
}

export function upsertProject(store: SQLiteStore, project: ProjectRecord): void {
  store.upsertRecord({ kind: PK.project, id: project.id, taskID: undefined, sortAt: project.updatedAt, value: project })
}

export function fetchPrincipals(store: SQLiteStore): PrincipalRecord[] {
  return store.fetchRecords<PrincipalRecord>(PK.principal)
}

export function fetchPrincipal(store: SQLiteStore, id: UUID): PrincipalRecord | undefined {
  return store.fetchRecord<PrincipalRecord>(PK.principal, id)
}

export function upsertPrincipal(store: SQLiteStore, principal: PrincipalRecord): void {
  store.upsertRecord({ kind: PK.principal, id: principal.id, taskID: undefined, sortAt: principal.updatedAt, value: principal })
}

export function fetchProjectActors(store: SQLiteStore): ProjectActorRecord[] {
  return store.fetchRecords<ProjectActorRecord>(PK.projectActor)
}

export function fetchProjectActor(store: SQLiteStore, id: UUID): ProjectActorRecord | undefined {
  return store.fetchRecord<ProjectActorRecord>(PK.projectActor, id)
}

export function upsertProjectActor(store: SQLiteStore, actor: ProjectActorRecord): void {
  store.upsertRecord({ kind: PK.projectActor, id: actor.id, taskID: undefined, sortAt: actor.updatedAt, value: actor })
}

export function fetchProjectMemberships(store: SQLiteStore): ProjectMembershipRecord[] {
  return store.fetchRecords<ProjectMembershipRecord>(PK.membership)
}

export function upsertProjectMembership(store: SQLiteStore, membership: ProjectMembershipRecord): void {
  store.upsertRecord({ kind: PK.membership, id: membership.id, taskID: undefined, sortAt: membership.updatedAt, value: membership })
}

export function fetchDelegations(store: SQLiteStore): DelegationRecord[] {
  return store.fetchRecords<DelegationRecord>(PK.delegation)
}

export function upsertDelegation(store: SQLiteStore, delegation: DelegationRecord): void {
  store.upsertRecord({ kind: PK.delegation, id: delegation.id, taskID: undefined, sortAt: delegation.updatedAt, value: delegation })
}

export function fetchProjectWorkspaces(store: SQLiteStore): ProjectWorkspaceRecord[] {
  return store.fetchRecords<ProjectWorkspaceRecord>(PK.workspace)
}

export function fetchProjectWorkspace(store: SQLiteStore, id: UUID): ProjectWorkspaceRecord | undefined {
  return store.fetchRecord<ProjectWorkspaceRecord>(PK.workspace, id)
}

export function upsertProjectWorkspace(store: SQLiteStore, workspace: ProjectWorkspaceRecord): void {
  store.upsertRecord({ kind: PK.workspace, id: workspace.id, taskID: workspace.taskID, sortAt: workspace.updatedAt, value: workspace })
}

export function fetchTaskProjectLinks(store: SQLiteStore): TaskProjectLink[] {
  return store.fetchRecords<TaskProjectLink>(PK.taskLink)
}

export function fetchTaskProjectLink(store: SQLiteStore, id: UUID): TaskProjectLink | undefined {
  return store.fetchRecord<TaskProjectLink>(PK.taskLink, id)
}

export function upsertTaskProjectLink(store: SQLiteStore, link: TaskProjectLink): void {
  store.upsertRecord({ kind: PK.taskLink, id: link.id, taskID: link.taskID, sortAt: link.updatedAt, value: link })
}

export function fetchTaskLeases(store: SQLiteStore): TaskLeaseRecord[] {
  return store.fetchRecords<TaskLeaseRecord>(PK.lease)
}

export function fetchTaskLease(store: SQLiteStore, id: UUID): TaskLeaseRecord | undefined {
  return store.fetchRecord<TaskLeaseRecord>(PK.lease, id)
}

export function upsertTaskLease(store: SQLiteStore, lease: TaskLeaseRecord): void {
  store.upsertRecord({ kind: PK.lease, id: lease.id, taskID: lease.taskID, sortAt: lease.lastHeartbeatAt, value: lease })
}

export function fetchProjectArtifacts(store: SQLiteStore): ProjectArtifactRecord[] {
  return store.fetchRecords<ProjectArtifactRecord>(PK.artifact)
}

export function fetchProjectArtifact(store: SQLiteStore, id: UUID): ProjectArtifactRecord | undefined {
  return store.fetchRecord<ProjectArtifactRecord>(PK.artifact, id)
}

export function upsertProjectArtifact(store: SQLiteStore, artifact: ProjectArtifactRecord): void {
  store.upsertRecord({ kind: PK.artifact, id: artifact.id, taskID: artifact.taskID, sortAt: artifact.updatedAt, value: artifact })
}

export function fetchProjectReviews(store: SQLiteStore): ProjectReviewRecord[] {
  return store.fetchRecords<ProjectReviewRecord>(PK.review)
}

export function upsertProjectReview(store: SQLiteStore, review: ProjectReviewRecord): void {
  store.upsertRecord({ kind: PK.review, id: review.id, taskID: review.taskID, sortAt: review.resolvedAt ?? review.createdAt, value: review })
}

export function fetchProjectApprovals(store: SQLiteStore): ProjectApprovalRecord[] {
  return store.fetchRecords<ProjectApprovalRecord>(PK.approval)
}

export function upsertProjectApproval(store: SQLiteStore, approval: ProjectApprovalRecord): void {
  store.upsertRecord({ kind: PK.approval, id: approval.id, taskID: approval.taskID, sortAt: approval.resolvedAt ?? approval.createdAt, value: approval })
}

export function fetchProjectContextPacks(store: SQLiteStore): ProjectContextPackRecord[] {
  return store.fetchRecords<ProjectContextPackRecord>(PK.contextPack)
}

export function fetchProjectContextPack(store: SQLiteStore, id: UUID): ProjectContextPackRecord | undefined {
  return store.fetchRecord<ProjectContextPackRecord>(PK.contextPack, id)
}

export function insertProjectContextPack(store: SQLiteStore, pack: ProjectContextPackRecord): void {
  store.insertImmutableRecord({ kind: PK.contextPack, id: pack.id, taskID: pack.taskID, sortAt: pack.createdAt, value: pack })
}
