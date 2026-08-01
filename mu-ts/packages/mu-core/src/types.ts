import type { UUID } from './identity.ts'

// ---------------------------------------------------------------------------
// String-union enums mirroring the Swift `enum Foo: String, Codable` types.
// ---------------------------------------------------------------------------

export const TaskStatus = {
  draft: 'draft',
  ready: 'ready',
  running: 'running',
  handoffPending: 'handoff_pending',
  blocked: 'blocked',
  completed: 'completed',
  failed: 'failed',
  cancelled: 'cancelled',
} as const
export type TaskStatus = (typeof TaskStatus)[keyof typeof TaskStatus]

export const TASK_STATUS_DISPLAY: Record<TaskStatus, string> = {
  draft: 'Draft',
  ready: 'Ready',
  running: 'Running',
  handoff_pending: 'Handoff pending',
  blocked: 'Blocked',
  completed: 'Completed',
  failed: 'Failed',
  cancelled: 'Cancelled',
}

export function taskStatusDisplayName(status: TaskStatus): string {
  return TASK_STATUS_DISPLAY[status]
}

export function isTerminalTaskStatus(status: TaskStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'cancelled'
}

export const RunState = {
  created: 'created',
  starting: 'starting',
  active: 'active',
  checkpointed: 'checkpointed',
  blocked: 'blocked',
  degraded: 'degraded',
  ambiguous: 'ambiguous',
  completed: 'completed',
  failed: 'failed',
  cancelled: 'cancelled',
} as const
export type RunState = (typeof RunState)[keyof typeof RunState]

export const RunPurpose = {
  execution: 'execution',
  delegation: 'delegation',
  replan: 'replan',
  review: 'review',
} as const
export type RunPurpose = (typeof RunPurpose)[keyof typeof RunPurpose]

export const HandoffStatus = {
  proposed: 'proposed',
  validating: 'validating',
  accepted: 'accepted',
  rejected: 'rejected',
  expired: 'expired',
  cancelled: 'cancelled',
} as const
export type HandoffStatus = (typeof HandoffStatus)[keyof typeof HandoffStatus]

export const EndpointStatus = {
  discovered: 'discovered',
  probing: 'probing',
  active: 'active',
  degraded: 'degraded',
  quarantined: 'quarantined',
  offline: 'offline',
} as const
export type EndpointStatus = (typeof EndpointStatus)[keyof typeof EndpointStatus]

export const EndpointLocation = {
  local: 'local',
  hosted: 'hosted',
  remote: 'remote',
} as const
export type EndpointLocation = (typeof EndpointLocation)[keyof typeof EndpointLocation]

export const IntegrationProvenance = {
  synthetic: 'synthetic',
  vendorProtocol: 'vendor_protocol',
  vendorSDK: 'vendor_sdk',
  vendorCLI: 'vendor_cli',
  artifactOnly: 'artifact_only',
} as const
export type IntegrationProvenance = (typeof IntegrationProvenance)[keyof typeof IntegrationProvenance]

export const INTEGRATION_PROVENANCE_DISPLAY: Record<IntegrationProvenance, string> = {
  synthetic: 'Synthetic fixture',
  vendor_protocol: 'Vendor protocol',
  vendor_sdk: 'Vendor SDK',
  vendor_cli: 'Vendor CLI',
  artifact_only: 'Artifact only',
}

export const PermissionModel = {
  fineGrained: 'fine_grained',
  promptGate: 'prompt_gate',
  allOrNothing: 'all_or_nothing',
  none: 'none',
  unknown: 'unknown',
} as const
export type PermissionModel = (typeof PermissionModel)[keyof typeof PermissionModel]

export const RuntimeCapability = {
  start: 'start',
  continueRun: 'continue',
  replan: 'replan',
  cancel: 'cancel',
  streamEvents: 'stream_events',
  contributeCheckpointEvidence: 'contribute_checkpoint_evidence',
  discoverGitArtifacts: 'discover_git_artifacts',
  approvalIntent: 'approval_intent',
} as const
export type RuntimeCapability = (typeof RuntimeCapability)[keyof typeof RuntimeCapability]

export function runtimeCapabilityDisplayName(capability: RuntimeCapability): string {
  return capability.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
}

export const AgentRole = {
  orchestrator: 'orchestrator',
  builder: 'builder',
  researcher: 'researcher',
  reviewer: 'reviewer',
} as const
export type AgentRole = (typeof AgentRole)[keyof typeof AgentRole]

export const AgentAvailability = {
  available: 'available',
  busy: 'busy',
  offline: 'offline',
} as const
export type AgentAvailability = (typeof AgentAvailability)[keyof typeof AgentAvailability]

export const RegistryEntityKind = {
  agentIdentity: 'agent_identity',
  runtimeEndpoint: 'runtime_endpoint',
} as const
export type RegistryEntityKind = (typeof RegistryEntityKind)[keyof typeof RegistryEntityKind]

export const ChatAuthorKind = {
  user: 'user',
  agent: 'agent',
  system: 'system',
} as const
export type ChatAuthorKind = (typeof ChatAuthorKind)[keyof typeof ChatAuthorKind]

export const ChatDeliveryState = {
  local: 'local',
  awaitingSession: 'awaiting_session',
  queued: 'queued',
  routing: 'routing',
  sending: 'sending',
  delivered: 'delivered',
  mirrored: 'mirrored',
  failed: 'failed',
  ambiguous: 'ambiguous',
  cancelled: 'cancelled',
} as const
export type ChatDeliveryState = (typeof ChatDeliveryState)[keyof typeof ChatDeliveryState]

export const RuntimeSessionState = {
  connecting: 'connecting',
  idle: 'idle',
  working: 'working',
  awaitingApproval: 'awaiting_approval',
  completed: 'completed',
  failed: 'failed',
  disconnected: 'disconnected',
  detached: 'detached',
} as const
export type RuntimeSessionState = (typeof RuntimeSessionState)[keyof typeof RuntimeSessionState]

export const RUNTIME_SESSION_STATE_DISPLAY: Record<RuntimeSessionState, string> = {
  connecting: 'Connecting',
  idle: 'Ready',
  working: 'Working',
  awaiting_approval: 'Needs approval',
  completed: 'Completed',
  failed: 'Failed',
  disconnected: 'Disconnected',
  detached: 'Detached',
}

export const RuntimeInteractionKind = {
  approval: 'approval',
  directory: 'directory',
  plan: 'plan',
  question: 'question',
} as const
export type RuntimeInteractionKind = (typeof RuntimeInteractionKind)[keyof typeof RuntimeInteractionKind]

export const RuntimeInteractionState = {
  pending: 'pending',
  approved: 'approved',
  denied: 'denied',
  answered: 'answered',
  superseded: 'superseded',
} as const
export type RuntimeInteractionState =
  (typeof RuntimeInteractionState)[keyof typeof RuntimeInteractionState]

// ---------------------------------------------------------------------------
// ConversationProvider: open raw-string identifier (extensible, like Swift).
// ---------------------------------------------------------------------------

export const CONVERSATION_PROVIDER = {
  codex: 'codex',
  claudeCode: 'claude_code',
  openWorker: 'openworker',
} as const

export interface ConversationProvider {
  readonly rawValue: string
}

export function provider(rawValue: string): ConversationProvider {
  return { rawValue }
}

export const CODE_PROVIDER: ConversationProvider = provider(CONVERSATION_PROVIDER.codex)
export const CLAUDE_CODE_PROVIDER: ConversationProvider = provider(
  CONVERSATION_PROVIDER.claudeCode,
)
export const OPEN_WORKER_PROVIDER: ConversationProvider = provider(
  CONVERSATION_PROVIDER.openWorker,
)

const PROVIDER_DISPLAY: Record<string, string> = {
  codex: 'Codex',
  claude_code: 'Claude Code',
  openworker: 'OpenWorker',
}

export function providerDisplayName(p: ConversationProvider): string {
  return PROVIDER_DISPLAY[p.rawValue] ?? p.rawValue
}

export function providerEqual(a: ConversationProvider, b: ConversationProvider): boolean {
  return a.rawValue === b.rawValue
}

// ---------------------------------------------------------------------------
// AgentRuntimeSurfaceKind / AgentRuntimeIdentityBasis
// ---------------------------------------------------------------------------

export const AgentRuntimeSurfaceKind = {
  desktopApplication: 'desktop_application',
  terminalCLI: 'terminal_cli',
  editorExtension: 'editor_extension',
  automation: 'automation',
  localService: 'local_service',
  remoteService: 'remote_service',
  historyArtifact: 'history_artifact',
  unknown: 'unknown',
} as const
export type AgentRuntimeSurfaceKind =
  (typeof AgentRuntimeSurfaceKind)[keyof typeof AgentRuntimeSurfaceKind]

export const AgentRuntimeIdentityBasis = {
  desktopSingleton: 'desktop_singleton',
  terminalIdentifier: 'terminal_identifier',
  sessionFallback: 'session_fallback',
  endpointFallback: 'endpoint_fallback',
  installation: 'installation',
  unknown: 'unknown',
} as const
export type AgentRuntimeIdentityBasis =
  (typeof AgentRuntimeIdentityBasis)[keyof typeof AgentRuntimeIdentityBasis]

/** Stable keys understood by Runtime import/registration UI. */
export const RuntimeIdentityConfigurationKey = {
  provider: 'identity.provider',
  surfaceKind: 'identity.surface_kind',
  instanceLabel: 'identity.instance_label',
  terminalIdentifier: 'identity.terminal_identifier',
  workspacePath: 'identity.workspace_path',
  nativeSource: 'identity.native_source',
} as const

// ---------------------------------------------------------------------------
// AgentRuntimeInstanceIdentity
// ---------------------------------------------------------------------------

export interface AgentRuntimeInstanceIdentity {
  readonly provider: ConversationProvider
  readonly surfaceKind: AgentRuntimeSurfaceKind
  readonly identityBasis: AgentRuntimeIdentityBasis
  readonly stableInstanceKey: string
  readonly instanceLabel: string
  readonly terminalIdentifier?: string
  readonly executablePath?: string
  readonly nativeSessionID?: string
  readonly workspacePath?: string
  readonly sourceLocation?: string
  readonly nativeSource?: string
}

export function agentRuntimeInstanceIdentity(
  params: AgentRuntimeInstanceIdentity,
): AgentRuntimeInstanceIdentity {
  return params
}

export function hasConcreteTerminalIdentity(identity: AgentRuntimeInstanceIdentity): boolean {
  return (
    identity.surfaceKind === 'terminal_cli' &&
    identity.identityBasis === 'terminal_identifier' &&
    (identity.terminalIdentifier ?? '') !== ''
  )
}

// ---------------------------------------------------------------------------
// Well-known runtime type IDs (mirrors ControlPlaneService static constants)
// ---------------------------------------------------------------------------

export const codexRuntimeTypeID = 'openai.codex/app-server'
export const claudeCodeRuntimeTypeID = 'anthropic.claude-code/cli'
export const openWorkerRuntimeTypeID = 'andrewyng.openworker/desktop'

export type UUIDRef = UUID
