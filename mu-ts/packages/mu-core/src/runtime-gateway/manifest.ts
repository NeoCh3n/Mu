import type { UUID } from '../identity.ts'
import type { AgentRuntimeInstanceIdentity, ConversationProvider } from '../types.ts'

export const AgentConnectionKind = {
  managedRuntime: 'managed_runtime',
  connectedAgent: 'connected_agent',
  toolHost: 'tool_host',
} as const
export type AgentConnectionKind = (typeof AgentConnectionKind)[keyof typeof AgentConnectionKind]

export const RuntimeControlMode = {
  managed: 'managed',
  managedLimited: 'managed_limited',
  attached: 'attached',
  historyOnly: 'history_only',
  submitOnly: 'submit_only',
} as const
export type RuntimeControlMode = (typeof RuntimeControlMode)[keyof typeof RuntimeControlMode]

export const AgentTrustLevel = {
  managed: 'managed',
  connected: 'connected',
  submitOnly: 'submit_only',
} as const
export type AgentTrustLevel = (typeof AgentTrustLevel)[keyof typeof AgentTrustLevel]

export const RuntimeGatewayOperation = {
  discoverHistory: 'history.discover',
  readHistory: 'history.read',
  createSession: 'session.create',
  attachSession: 'session.attach',
  submitInput: 'input.submit',
  observeEvents: 'events.observe',
  interrupt: 'interrupt',
  resume: 'resume',
  resolveApproval: 'approval.resolve',
  listArtifacts: 'artifact.list',
  submitArtifact: 'artifact.submit',
  acceptTaskLease: 'task_lease.accept',
  renewTaskLease: 'task_lease.renew',
  publishProjectEvent: 'project_event.publish',
  completeTask: 'task.complete',
  failTask: 'task.fail',
  searchContext: 'context.search',
  getContextRecord: 'context.get_record',
} as const
export type RuntimeGatewayOperation =
  (typeof RuntimeGatewayOperation)[keyof typeof RuntimeGatewayOperation]

export const ALL_RUNTIME_GATEWAY_OPERATIONS: readonly RuntimeGatewayOperation[] =
  Object.values(RuntimeGatewayOperation)

const OPERATION_DISPLAY: Record<RuntimeGatewayOperation, string> = {
  'history.discover': 'Discover history',
  'history.read': 'Read history',
  'session.create': 'Create session',
  'session.attach': 'Attach session',
  'input.submit': 'Submit input',
  'events.observe': 'Observe events',
  interrupt: 'Interrupt',
  resume: 'Resume',
  'approval.resolve': 'Resolve approval',
  'artifact.list': 'List artifacts',
  'artifact.submit': 'Submit artifact',
  'task_lease.accept': 'Accept Task lease',
  'task_lease.renew': 'Renew Task lease',
  'project_event.publish': 'Publish Project event',
  'task.complete': 'Complete Task',
  'task.fail': 'Fail Task',
  'context.search': 'Search Context',
  'context.get_record': 'Get Context record',
}

export function runtimeGatewayOperationDisplayName(
  operation: RuntimeGatewayOperation,
): string {
  return OPERATION_DISPLAY[operation] ?? operation
}

export const RuntimeOperationSupport = {
  supported: 'supported',
  conditional: 'conditional',
  unsupported: 'unsupported',
} as const
export type RuntimeOperationSupport =
  (typeof RuntimeOperationSupport)[keyof typeof RuntimeOperationSupport]

export const RuntimeObservationFidelity = {
  nativeStream: 'native_stream',
  mirroredStream: 'mirrored_stream',
  polling: 'polling',
  snapshot: 'snapshot',
  none: 'none',
} as const
export type RuntimeObservationFidelity =
  (typeof RuntimeObservationFidelity)[keyof typeof RuntimeObservationFidelity]

export interface RuntimeGatewayOperationDeclaration {
  readonly operation: RuntimeGatewayOperation
  readonly support: RuntimeOperationSupport
  readonly condition?: string
}

export function supportedOperation(
  operation: RuntimeGatewayOperation,
): RuntimeGatewayOperationDeclaration {
  return { operation, support: 'supported' }
}

export function conditionalOperation(
  operation: RuntimeGatewayOperation,
  condition: string,
): RuntimeGatewayOperationDeclaration {
  return { operation, support: 'conditional', condition }
}

export function unsupportedOperation(
  operation: RuntimeGatewayOperation,
): RuntimeGatewayOperationDeclaration {
  return { operation, support: 'unsupported' }
}

/**
 * A probeable, provider-neutral capability statement. It is deliberately
 * more precise than the legacy RuntimeCapability summary used by older UI.
 */
export interface RuntimeGatewayManifest {
  readonly contractVersion: number
  readonly adapterID: string
  readonly provider: ConversationProvider
  readonly connectionKind: AgentConnectionKind
  readonly controlMode: RuntimeControlMode
  readonly trustLevel: AgentTrustLevel
  readonly observationFidelity: RuntimeObservationFidelity
  readonly operations: readonly RuntimeGatewayOperationDeclaration[]
  readonly instanceIdentity: AgentRuntimeInstanceIdentity
  readonly notes: readonly string[]
}

export function createRuntimeGatewayManifest(params: {
  contractVersion?: number
  adapterID: string
  provider: ConversationProvider
  connectionKind: AgentConnectionKind
  controlMode: RuntimeControlMode
  trustLevel: AgentTrustLevel
  observationFidelity: RuntimeObservationFidelity
  operations: readonly RuntimeGatewayOperationDeclaration[]
  instanceIdentity: AgentRuntimeInstanceIdentity
  notes?: readonly string[]
}): RuntimeGatewayManifest {
  return {
    contractVersion: params.contractVersion ?? 1,
    adapterID: params.adapterID,
    provider: params.provider,
    connectionKind: params.connectionKind,
    controlMode: params.controlMode,
    trustLevel: params.trustLevel,
    observationFidelity: params.observationFidelity,
    operations: [...params.operations].sort((a, b) =>
      a.operation < b.operation ? -1 : a.operation > b.operation ? 1 : 0,
    ),
    instanceIdentity: params.instanceIdentity,
    notes: params.notes ?? [],
  }
}

export function manifestSupportFor(
  manifest: RuntimeGatewayManifest,
  operation: RuntimeGatewayOperation,
): RuntimeOperationSupport {
  return manifest.operations.find((o) => o.operation === operation)?.support ?? 'unsupported'
}

export function manifestConditionFor(
  manifest: RuntimeGatewayManifest,
  operation: RuntimeGatewayOperation,
): string | undefined {
  return manifest.operations.find((o) => o.operation === operation)?.condition
}

export function manifestSupports(
  manifest: RuntimeGatewayManifest,
  operation: RuntimeGatewayOperation,
  endpointIsActive: boolean,
): boolean {
  switch (manifestSupportFor(manifest, operation)) {
    case 'supported':
      return true
    case 'conditional':
      return endpointIsActive
    case 'unsupported':
      return false
  }
}

/** Persisted probe snapshot; the endpoint UUID is the registration identity. */
export interface RuntimeAdapterRegistration {
  readonly id: UUID
  readonly endpointID: UUID
  readonly manifest: RuntimeGatewayManifest
  readonly probedAt: Date
}

export function createRuntimeAdapterRegistration(params: {
  endpointID: UUID
  manifest: RuntimeGatewayManifest
  probedAt?: Date
}): RuntimeAdapterRegistration {
  return {
    id: params.endpointID,
    endpointID: params.endpointID,
    manifest: params.manifest,
    probedAt: params.probedAt ?? new Date(),
  }
}
