import { uuid, type UUID } from './identity.ts'
import {
  AgentAvailability,
  AgentRole,
  type AgentRuntimeInstanceIdentity,
  type ChatAuthorKind,
  type ChatDeliveryState,
  type EndpointLocation,
  type EndpointStatus,
  type HandoffStatus,
  type IntegrationProvenance,
  type PermissionModel,
  type RegistryEntityKind,
  type RuntimeCapability,
  type RuntimeInteractionKind,
  type RuntimeInteractionState,
  type RuntimeSessionState,
  type ReasoningEffort,
  type RunPurpose,
  type RunState,
  type TaskStatus,
} from './types.ts'

// ---------------------------------------------------------------------------
// Record types mirroring Models.swift structs. All fields readonly; use the
// factory functions for construction. Optional fields are `undefined` when
// absent (Swift nil), and are omitted by encodeMuJSON.
// ---------------------------------------------------------------------------

export interface AgentIdentity {
  readonly id: UUID
  readonly displayName: string
  readonly shortName: string
  readonly role: AgentRole
  readonly summary: string
  readonly preferredEndpointID?: UUID
  readonly capabilityTags: readonly string[]
  readonly accentHex: string
  readonly availability: AgentAvailability
  readonly createdAt: Date
}

export function createAgentIdentity(params: {
  id?: UUID
  displayName: string
  shortName: string
  role: AgentRole
  summary: string
  preferredEndpointID?: UUID
  capabilityTags?: readonly string[]
  accentHex: string
  availability?: AgentAvailability
  createdAt?: Date
}): AgentIdentity {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    displayName: params.displayName,
    shortName: params.shortName,
    role: params.role,
    summary: params.summary,
    preferredEndpointID: params.preferredEndpointID,
    capabilityTags: params.capabilityTags ?? [],
    accentHex: params.accentHex,
    availability: params.availability ?? 'available',
    createdAt: now,
  }
}

export interface RegistryTombstone {
  readonly id: UUID
  readonly entityKind: RegistryEntityKind
  readonly displayName: string
  readonly deletedAt: Date
}

export function createRegistryTombstone(params: {
  id: UUID
  entityKind: RegistryEntityKind
  displayName: string
  deletedAt?: Date
}): RegistryTombstone {
  return {
    id: params.id,
    entityKind: params.entityKind,
    displayName: params.displayName,
    deletedAt: params.deletedAt ?? new Date(),
  }
}

export interface ChatEntry {
  readonly id: UUID
  readonly taskID: UUID
  readonly agentIdentityID?: UUID
  readonly targetAgentIdentityID?: UUID
  readonly targetEndpointID?: UUID
  readonly runID?: UUID
  readonly runtimeSessionBindingID?: UUID
  readonly nativeMessageIndex?: number
  readonly nativeMessageIndexLowerBound?: number
  readonly deliveryState?: ChatDeliveryState
  readonly routedText?: string
  readonly contextFreeRoutedText?: string
  readonly contextSnapshotID?: UUID
  readonly authorKind: ChatAuthorKind
  readonly authorName: string
  readonly text: string
  readonly createdAt: Date
  readonly updatedAt?: Date
}

export function createChatEntry(params: {
  id?: UUID
  taskID: UUID
  agentIdentityID?: UUID
  targetAgentIdentityID?: UUID
  targetEndpointID?: UUID
  runID?: UUID
  runtimeSessionBindingID?: UUID
  nativeMessageIndex?: number
  nativeMessageIndexLowerBound?: number
  deliveryState?: ChatDeliveryState
  routedText?: string
  contextFreeRoutedText?: string
  contextSnapshotID?: UUID
  authorKind: ChatAuthorKind
  authorName: string
  text: string
  createdAt?: Date
  updatedAt?: Date
}): ChatEntry {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    taskID: params.taskID,
    agentIdentityID: params.agentIdentityID,
    targetAgentIdentityID: params.targetAgentIdentityID,
    targetEndpointID: params.targetEndpointID,
    runID: params.runID,
    runtimeSessionBindingID: params.runtimeSessionBindingID,
    nativeMessageIndex: params.nativeMessageIndex,
    nativeMessageIndexLowerBound: params.nativeMessageIndexLowerBound,
    deliveryState: params.deliveryState,
    routedText: params.routedText,
    contextFreeRoutedText: params.contextFreeRoutedText,
    contextSnapshotID: params.contextSnapshotID,
    authorKind: params.authorKind,
    authorName: params.authorName,
    text: params.text,
    createdAt: now,
    updatedAt: params.updatedAt,
  }
}

export interface RuntimeSessionBinding {
  readonly id: UUID
  readonly taskID: UUID
  readonly projectID?: UUID
  readonly workspaceID?: UUID
  readonly actorID?: UUID
  readonly principalID?: UUID
  readonly taskLeaseID?: UUID
  readonly runID?: UUID
  readonly contextPackID?: UUID
  readonly endpointID: UUID
  readonly agentIdentityID?: UUID
  readonly nativeSessionID: string
  readonly nativeAgentName: string
  readonly workspacePath: string
  readonly model?: string
  readonly connectionMode: string
  readonly origin: string
  readonly state: RuntimeSessionState
  readonly lastSyncedMessageCount: number
  readonly lastActivitySummary: string
  readonly lastError?: string
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createRuntimeSessionBinding(params: {
  id?: UUID
  taskID: UUID
  projectID?: UUID
  workspaceID?: UUID
  actorID?: UUID
  principalID?: UUID
  taskLeaseID?: UUID
  runID?: UUID
  contextPackID?: UUID
  endpointID: UUID
  agentIdentityID?: UUID
  nativeSessionID: string
  nativeAgentName: string
  workspacePath: string
  model?: string
  connectionMode: string
  origin?: string
  state?: RuntimeSessionState
  lastSyncedMessageCount?: number
  lastActivitySummary?: string
  lastError?: string
  createdAt?: Date
  updatedAt?: Date
}): RuntimeSessionBinding {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    taskID: params.taskID,
    projectID: params.projectID,
    workspaceID: params.workspaceID,
    actorID: params.actorID,
    principalID: params.principalID,
    taskLeaseID: params.taskLeaseID,
    runID: params.runID,
    contextPackID: params.contextPackID,
    endpointID: params.endpointID,
    agentIdentityID: params.agentIdentityID,
    nativeSessionID: params.nativeSessionID,
    nativeAgentName: params.nativeAgentName,
    workspacePath: params.workspacePath,
    model: params.model,
    connectionMode: params.connectionMode,
    origin: params.origin ?? 'created_by_mu',
    state: params.state ?? 'connecting',
    lastSyncedMessageCount: params.lastSyncedMessageCount ?? 0,
    lastActivitySummary: params.lastActivitySummary ?? 'Connecting to the native session.',
    lastError: params.lastError,
    createdAt: now,
    updatedAt: params.updatedAt ?? now,
  }
}

export interface RuntimeInteractionRequest {
  readonly id: UUID
  readonly taskID: UUID
  readonly projectApprovalID?: UUID
  readonly bindingID: UUID
  readonly endpointID: UUID
  readonly nativeSessionID: string
  readonly nativeRequestID?: string
  readonly kind: RuntimeInteractionKind
  readonly title: string
  readonly detail: string
  readonly payload: Readonly<Record<string, string>>
  readonly state: RuntimeInteractionState
  readonly createdAt: Date
  readonly resolvedAt?: Date
}

export function createRuntimeInteractionRequest(params: {
  id?: UUID
  taskID: UUID
  projectApprovalID?: UUID
  bindingID: UUID
  endpointID: UUID
  nativeSessionID: string
  nativeRequestID?: string
  kind: RuntimeInteractionKind
  title: string
  detail?: string
  payload?: Readonly<Record<string, string>>
  state?: RuntimeInteractionState
  createdAt?: Date
  resolvedAt?: Date
}): RuntimeInteractionRequest {
  return {
    id: params.id ?? uuid(),
    taskID: params.taskID,
    projectApprovalID: params.projectApprovalID,
    bindingID: params.bindingID,
    endpointID: params.endpointID,
    nativeSessionID: params.nativeSessionID,
    nativeRequestID: params.nativeRequestID,
    kind: params.kind,
    title: params.title,
    detail: params.detail ?? '',
    payload: params.payload ?? {},
    state: params.state ?? 'pending',
    createdAt: params.createdAt ?? new Date(),
    resolvedAt: params.resolvedAt,
  }
}

export interface RuntimeArtifactRecord {
  readonly id: UUID
  readonly taskID: UUID
  readonly projectArtifactID?: UUID
  readonly bindingID: UUID
  readonly endpointID: UUID
  readonly nativeSessionID: string
  readonly relativePath: string
  readonly absolutePath?: string
  readonly name: string
  readonly kind: string
  readonly byteCount: number
  readonly modifiedAt: Date
  readonly observedAt: Date
}

export function createRuntimeArtifactRecord(params: {
  id?: UUID
  taskID: UUID
  projectArtifactID?: UUID
  bindingID: UUID
  endpointID: UUID
  nativeSessionID: string
  relativePath: string
  absolutePath?: string
  name: string
  kind: string
  byteCount: number
  modifiedAt: Date
  observedAt?: Date
}): RuntimeArtifactRecord {
  return {
    id: params.id ?? uuid(),
    taskID: params.taskID,
    projectArtifactID: params.projectArtifactID,
    bindingID: params.bindingID,
    endpointID: params.endpointID,
    nativeSessionID: params.nativeSessionID,
    relativePath: params.relativePath,
    absolutePath: params.absolutePath,
    name: params.name,
    kind: params.kind,
    byteCount: params.byteCount,
    modifiedAt: params.modifiedAt,
    observedAt: params.observedAt ?? new Date(),
  }
}

export interface TaskRecord {
  readonly id: UUID
  readonly projectID?: UUID
  readonly workspaceID?: UUID
  readonly requestedByActorID?: UUID
  readonly assignedActorID?: UUID
  readonly title: string
  readonly objective: string
  readonly successCriteria: readonly string[]
  readonly constraints: readonly string[]
  readonly pendingSteps: readonly string[]
  readonly repositoryPath: string
  readonly status: TaskStatus
  readonly currentEndpointID?: UUID
  readonly currentRunID?: UUID
  readonly assignedAgentIdentityID?: UUID
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createTaskRecord(params: {
  id?: UUID
  projectID?: UUID
  workspaceID?: UUID
  requestedByActorID?: UUID
  assignedActorID?: UUID
  title: string
  objective: string
  successCriteria?: readonly string[]
  constraints?: readonly string[]
  pendingSteps?: readonly string[]
  repositoryPath: string
  status?: TaskStatus
  currentEndpointID?: UUID
  currentRunID?: UUID
  assignedAgentIdentityID?: UUID
  createdAt?: Date
  updatedAt?: Date
}): TaskRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    workspaceID: params.workspaceID,
    requestedByActorID: params.requestedByActorID,
    assignedActorID: params.assignedActorID,
    title: params.title,
    objective: params.objective,
    successCriteria: params.successCriteria ?? [],
    constraints: params.constraints ?? [],
    pendingSteps: params.pendingSteps ?? [],
    repositoryPath: params.repositoryPath,
    status: params.status ?? 'ready',
    currentEndpointID: params.currentEndpointID,
    currentRunID: params.currentRunID,
    assignedAgentIdentityID: params.assignedAgentIdentityID,
    createdAt: now,
    updatedAt: params.updatedAt ?? now,
  }
}

export interface RunRecord {
  readonly id: UUID
  readonly taskID: UUID
  readonly projectID?: UUID
  readonly workspaceID?: UUID
  readonly actorID?: UUID
  readonly principalID?: UUID
  readonly taskLeaseID?: UUID
  readonly contextPackID?: UUID
  readonly endpointID: UUID
  readonly actorName: string
  readonly purpose: RunPurpose
  readonly state: RunState
  readonly plan: readonly string[]
  readonly nativeThreadID?: string
  readonly nativeTurnID?: string
  readonly nativeOutput?: string
  /** Resolved model/reasoning budget selected for this turn. */
  readonly reasoningEffort?: ReasoningEffort
  readonly agentIdentityID?: UUID
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createRunRecord(params: {
  id?: UUID
  taskID: UUID
  projectID?: UUID
  workspaceID?: UUID
  actorID?: UUID
  principalID?: UUID
  taskLeaseID?: UUID
  contextPackID?: UUID
  endpointID: UUID
  actorName: string
  purpose: RunPurpose
  state: RunState
  plan?: readonly string[]
  nativeThreadID?: string
  nativeTurnID?: string
  nativeOutput?: string
  reasoningEffort?: ReasoningEffort
  agentIdentityID?: UUID
  createdAt?: Date
  updatedAt?: Date
}): RunRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    taskID: params.taskID,
    projectID: params.projectID,
    workspaceID: params.workspaceID,
    actorID: params.actorID,
    principalID: params.principalID,
    taskLeaseID: params.taskLeaseID,
    contextPackID: params.contextPackID,
    endpointID: params.endpointID,
    actorName: params.actorName,
    purpose: params.purpose,
    state: params.state,
    plan: params.plan ?? [],
    nativeThreadID: params.nativeThreadID,
    nativeTurnID: params.nativeTurnID,
    nativeOutput: params.nativeOutput,
    reasoningEffort: params.reasoningEffort,
    agentIdentityID: params.agentIdentityID,
    createdAt: now,
    updatedAt: params.updatedAt ?? now,
  }
}

export interface RuntimeEndpoint {
  readonly id: UUID
  readonly runtimeTypeID: string
  readonly displayName: string
  readonly adapterVersion: string
  readonly runtimeVersion: string
  readonly location: EndpointLocation
  readonly provenance: IntegrationProvenance
  readonly permissionModel: PermissionModel
  readonly capabilities: ReadonlySet<RuntimeCapability>
  readonly status: EndpointStatus
  readonly guaranteeNote: string
  readonly lastProbedAt: Date
  readonly nativeConfiguration?: Readonly<Record<string, string>>
  readonly instanceIdentity?: AgentRuntimeInstanceIdentity
}

export function createRuntimeEndpoint(params: {
  id?: UUID
  runtimeTypeID: string
  displayName: string
  adapterVersion: string
  runtimeVersion: string
  location: EndpointLocation
  provenance: IntegrationProvenance
  permissionModel: PermissionModel
  capabilities?: ReadonlySet<RuntimeCapability>
  status: EndpointStatus
  guaranteeNote: string
  lastProbedAt?: Date
  nativeConfiguration?: Readonly<Record<string, string>>
  instanceIdentity?: AgentRuntimeInstanceIdentity
}): RuntimeEndpoint {
  return {
    id: params.id ?? uuid(),
    runtimeTypeID: params.runtimeTypeID,
    displayName: params.displayName,
    adapterVersion: params.adapterVersion,
    runtimeVersion: params.runtimeVersion,
    location: params.location,
    provenance: params.provenance,
    permissionModel: params.permissionModel,
    capabilities: params.capabilities ?? new Set(),
    status: params.status,
    guaranteeNote: params.guaranteeNote,
    lastProbedAt: params.lastProbedAt ?? new Date(),
    nativeConfiguration: params.nativeConfiguration,
    instanceIdentity: params.instanceIdentity,
  }
}

/**
 * Stable grouping key used by the UI and cleanup route. A discovered record
 * is the same local instance when it reports the same identity or executable;
 * otherwise the fallback is deliberately conservative and only groups exact
 * runtime-type/display-name copies.
 */
export function runtimeEndpointIdentityKey(endpoint: RuntimeEndpoint): string {
  const identity = endpoint.instanceIdentity
  if (identity?.stableInstanceKey !== undefined) {
    return `identity:${identity.provider.rawValue}:${identity.stableInstanceKey}`
  }
  const executable = endpoint.nativeConfiguration?.['executable']
  if (executable !== undefined) {
    return `executable:${endpoint.runtimeTypeID}:${executable}`
  }
  return `unidentified:${endpoint.runtimeTypeID}:${endpoint.displayName.trim().toLowerCase()}`
}

/**
 * A runtime is useful once it is verified or carries concrete local evidence.
 * The control plane may still derive an endpoint-scoped fallback identity for
 * host calls, but that synthetic identity must not make a blank discovery look
 * configured in the registry UI.
 */
export function hasRuntimeEndpointEvidence(endpoint: RuntimeEndpoint): boolean {
  if (endpoint.status !== 'discovered') return true

  const configuration = endpoint.nativeConfiguration ?? {}
  const configuredValue = (key: string): boolean => {
    const value = configuration[key]
    return typeof value === 'string' && value.trim() !== ''
  }
  if (
    configuredValue('executable')
    || configuredValue('application_path')
    || configuredValue('bundle_identifier')
    || configuredValue('terminal_id')
    || configuredValue('tty')
    || Object.keys(configuration).some((key) => key.startsWith('identity.') && configuredValue(key))
  ) return true

  const identity = endpoint.instanceIdentity
  if (identity === undefined) return false
  if (identity.identityBasis !== 'installation') return true
  if (
    identity.executablePath !== undefined
    || identity.terminalIdentifier !== undefined
    || identity.nativeSource !== undefined
    || identity.workspacePath !== undefined
    || identity.surfaceKind === 'desktop_application'
  ) return true
  return identity.stableInstanceKey !== `${endpoint.runtimeTypeID}:${endpoint.id}`
}

/** A runtime is useful once it is verified or has enough local identity to configure. */
export function isUsefulRuntimeEndpoint(endpoint: RuntimeEndpoint): boolean {
  return hasRuntimeEndpointEvidence(endpoint)
}

/**
 * Returns only the redundant low-confidence discoveries. One newest record per
 * conservative identity group is retained, so cleanup cannot remove distinct
 * terminals or desktop instances.
 */
export function duplicateDiscoveredRuntimeEndpointIDs(
  endpoints: readonly RuntimeEndpoint[],
): UUID[] {
  const groups = new Map<string, RuntimeEndpoint[]>()
  for (const endpoint of endpoints) {
    if (endpoint.status !== 'discovered' || isUsefulRuntimeEndpoint(endpoint)) continue
    const key = runtimeEndpointIdentityKey(endpoint)
    groups.set(key, [...(groups.get(key) ?? []), endpoint])
  }
  return [...groups.values()].flatMap((items) => items
    .sort((left, right) => right.lastProbedAt.getTime() - left.lastProbedAt.getTime())
    .slice(1)
    .map((endpoint) => endpoint.id))
}

// ---------------------------------------------------------------------------
// Vendor result types
// ---------------------------------------------------------------------------

export interface CodexProbeResult {
  readonly userAgent: string
  readonly platformOS: string
  readonly signedIn: boolean
  readonly observedThreadCount: number
}

export interface CodexReplanResult {
  readonly threadID: string
  readonly turnID: string
  readonly output: string
  readonly status: string
}

export interface CodexTurnResult {
  readonly threadID: string
  readonly turnID: string
  readonly output: string
  readonly status: string
  readonly errorMessage?: string
  readonly historyReconciled: boolean
}

export interface RepositorySnapshot {
  readonly path: string
  readonly isGitRepository: boolean
  readonly branch: string
  readonly baseCommit: string
  readonly headCommit: string
  readonly isDirty: boolean
  readonly trackedPatchURI?: string
  readonly trackedPatchSHA256?: string
  readonly untrackedManifestURI?: string
  readonly untrackedManifestSHA256?: string
  readonly untrackedFiles: readonly string[]
}

export function createRepositorySnapshot(params: {
  path: string
  isGitRepository: boolean
  branch?: string
  baseCommit?: string
  headCommit?: string
  isDirty?: boolean
  trackedPatchURI?: string
  trackedPatchSHA256?: string
  untrackedManifestURI?: string
  untrackedManifestSHA256?: string
  untrackedFiles?: readonly string[]
}): RepositorySnapshot {
  return {
    path: params.path,
    isGitRepository: params.isGitRepository,
    branch: params.branch ?? '',
    baseCommit: params.baseCommit ?? '',
    headCommit: params.headCommit ?? '',
    isDirty: params.isDirty ?? false,
    trackedPatchURI: params.trackedPatchURI,
    trackedPatchSHA256: params.trackedPatchSHA256,
    untrackedManifestURI: params.untrackedManifestURI,
    untrackedManifestSHA256: params.untrackedManifestSHA256,
    untrackedFiles: params.untrackedFiles ?? [],
  }
}

export interface CheckpointContent {
  readonly schemaVersion: string
  readonly workspaceID: string
  readonly taskID: UUID
  readonly sourceRunID?: UUID
  readonly sourceEndpointID: UUID
  readonly objective: string
  readonly successCriteria: readonly string[]
  readonly completedSteps: readonly string[]
  readonly pendingSteps: readonly string[]
  readonly acceptedDecisions: readonly string[]
  readonly rejectedAlternatives: readonly string[]
  readonly constraints: readonly string[]
  readonly permissionIntents: readonly string[]
  readonly repository: RepositorySnapshot
  readonly verificationChecks: readonly string[]
  readonly openQuestions: readonly string[]
  readonly blockers: readonly string[]
  readonly recommendedSemantic: string
  readonly createdAt: Date
}

export function createCheckpointContent(params: {
  schemaVersion?: string
  workspaceID?: string
  taskID: UUID
  sourceRunID?: UUID
  sourceEndpointID: UUID
  objective: string
  successCriteria: readonly string[]
  completedSteps?: readonly string[]
  pendingSteps: readonly string[]
  acceptedDecisions?: readonly string[]
  rejectedAlternatives?: readonly string[]
  constraints: readonly string[]
  permissionIntents?: readonly string[]
  repository: RepositorySnapshot
  verificationChecks?: readonly string[]
  openQuestions?: readonly string[]
  blockers?: readonly string[]
  recommendedSemantic?: string
  createdAt?: Date
}): CheckpointContent {
  return {
    schemaVersion: params.schemaVersion ?? '0.1',
    workspaceID: params.workspaceID ?? 'local',
    taskID: params.taskID,
    sourceRunID: params.sourceRunID,
    sourceEndpointID: params.sourceEndpointID,
    objective: params.objective,
    successCriteria: params.successCriteria,
    completedSteps: params.completedSteps ?? [],
    pendingSteps: params.pendingSteps,
    acceptedDecisions: params.acceptedDecisions ?? [],
    rejectedAlternatives: params.rejectedAlternatives ?? [],
    constraints: params.constraints,
    permissionIntents: params.permissionIntents ?? ['filesystem.workspace_write'],
    repository: params.repository,
    verificationChecks: params.verificationChecks ?? [],
    openQuestions: params.openQuestions ?? [],
    blockers: params.blockers ?? [],
    recommendedSemantic: params.recommendedSemantic ?? 'replan',
    createdAt: params.createdAt ?? new Date(),
  }
}

export interface CheckpointRecord {
  readonly id: UUID
  readonly taskID: UUID
  readonly sourceEndpointID: UUID
  readonly contentHash: string
  readonly content: CheckpointContent
  readonly createdAt: Date
}

export interface HandoffRecord {
  readonly id: UUID
  readonly taskID: UUID
  readonly checkpointID: UUID
  readonly sourceEndpointID: UUID
  readonly receiverEndpointID: UUID
  readonly status: HandoffStatus
  readonly validationMessage: string
  readonly rejectionReason?: string
  readonly createdAt: Date
  readonly resolvedAt?: Date
}

export function createHandoffRecord(params: {
  id?: UUID
  taskID: UUID
  checkpointID: UUID
  sourceEndpointID: UUID
  receiverEndpointID: UUID
  status?: HandoffStatus
  validationMessage?: string
  rejectionReason?: string
  createdAt?: Date
  resolvedAt?: Date
}): HandoffRecord {
  return {
    id: params.id ?? uuid(),
    taskID: params.taskID,
    checkpointID: params.checkpointID,
    sourceEndpointID: params.sourceEndpointID,
    receiverEndpointID: params.receiverEndpointID,
    status: params.status ?? 'proposed',
    validationMessage: params.validationMessage ?? '',
    rejectionReason: params.rejectionReason,
    createdAt: params.createdAt ?? new Date(),
    resolvedAt: params.resolvedAt,
  }
}

export interface LedgerEvent {
  readonly sequence: number
  readonly id: UUID
  readonly schemaVersion?: string
  readonly projectID?: UUID
  readonly actorID?: UUID
  readonly principalID?: UUID
  readonly workspaceID?: UUID
  readonly artifactID?: UUID
  readonly reviewID?: UUID
  readonly approvalID?: UUID
  readonly commandID?: UUID
  readonly correlationID?: UUID
  readonly taskID?: UUID
  readonly runID?: UUID
  readonly type: string
  readonly summary: string
  readonly payload: Readonly<Record<string, string>>
  readonly causalParentID?: UUID
  readonly occurredAt: Date
}

export function createLedgerEvent(params: {
  sequence?: number
  id?: UUID
  schemaVersion?: string
  projectID?: UUID
  actorID?: UUID
  principalID?: UUID
  workspaceID?: UUID
  artifactID?: UUID
  reviewID?: UUID
  approvalID?: UUID
  commandID?: UUID
  correlationID?: UUID
  taskID?: UUID
  runID?: UUID
  type: string
  summary: string
  payload?: Readonly<Record<string, string>>
  causalParentID?: UUID
  occurredAt?: Date
}): LedgerEvent {
  return {
    sequence: params.sequence ?? 0,
    id: params.id ?? uuid(),
    schemaVersion: params.schemaVersion ?? '1.0',
    projectID: params.projectID,
    actorID: params.actorID,
    principalID: params.principalID,
    workspaceID: params.workspaceID,
    artifactID: params.artifactID,
    reviewID: params.reviewID,
    approvalID: params.approvalID,
    commandID: params.commandID,
    correlationID: params.correlationID,
    taskID: params.taskID,
    runID: params.runID,
    type: params.type,
    summary: params.summary,
    payload: params.payload ?? {},
    causalParentID: params.causalParentID,
    occurredAt: params.occurredAt ?? new Date(),
  }
}
