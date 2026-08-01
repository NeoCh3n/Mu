import { MuError } from '../errors.ts'
import type { RuntimeEndpoint } from '../models.ts'
import {
  CLAUDE_CODE_PROVIDER,
  CODE_PROVIDER,
  OPEN_WORKER_PROVIDER,
  claudeCodeRuntimeTypeID,
  codexRuntimeTypeID,
  openWorkerRuntimeTypeID,
} from '../types.ts'
import { createBuiltinRuntimeGatewayAdapter, type RuntimeGatewayAdapter } from './adapter.ts'
import { resolvedInstanceIdentity } from './identity.ts'
import {
  ALL_RUNTIME_GATEWAY_OPERATIONS,
  conditionalOperation,
  runtimeGatewayOperationDisplayName,
  supportedOperation,
  unsupportedOperation,
  type RuntimeGatewayManifest,
  type RuntimeGatewayOperation,
} from './manifest.ts'

const codex = createBuiltinRuntimeGatewayAdapter({
  adapterID: 'mu.runtime.codex-app-server',
  provider: CODE_PROVIDER,
  connectionKind: 'managed_runtime',
  controlMode: 'managed_limited',
  trustLevel: 'managed',
  observationFidelity: 'mirrored_stream',
  declarations: [
    supportedOperation('history.discover'),
    supportedOperation('history.read'),
    conditionalOperation('session.create', 'Requires an active official App Server probe.'),
    conditionalOperation(
      'input.submit',
      'Requires an active thread in the exact Project workspace.',
    ),
    conditionalOperation(
      'events.observe',
      'Mu mirrors visible assistant output; reasoning stays private.',
    ),
    conditionalOperation('interrupt', 'Requires a recorded native thread and active turn.'),
    conditionalOperation('resume', 'Requires a recorded persistent native thread.'),
    unsupportedOperation('approval.resolve'),
    unsupportedOperation('artifact.list'),
    supportedOperation('artifact.submit'),
    conditionalOperation('task_lease.accept', 'Requires an active endpoint.'),
    conditionalOperation('task_lease.renew', 'Requires an active endpoint.'),
    supportedOperation('project_event.publish'),
    supportedOperation('task.complete'),
    supportedOperation('task.fail'),
    conditionalOperation(
      'context.search',
      'Requires the exact active Runtime binding and Run, plus a governed Context Pack with a delivered receipt.',
    ),
    conditionalOperation(
      'context.get_record',
      'Requires the exact active Runtime binding and Run, plus a governed Context Pack with a delivered receipt.',
    ),
  ],
  notes: [
    'Mu starts the official App Server process.',
    'Initial runs and continuations use a read-only sandbox with approvals disabled.',
  ],
})

const claudeCode = createBuiltinRuntimeGatewayAdapter({
  adapterID: 'mu.runtime.claude-code-cli',
  provider: CLAUDE_CODE_PROVIDER,
  connectionKind: 'managed_runtime',
  controlMode: 'managed_limited',
  trustLevel: 'managed',
  observationFidelity: 'mirrored_stream',
  declarations: [
    supportedOperation('history.discover'),
    supportedOperation('history.read'),
    conditionalOperation('session.create', 'Requires a verified, signed-in Claude Code CLI.'),
    unsupportedOperation('session.attach'),
    conditionalOperation('input.submit', 'Requires an active exact-workspace CLI session.'),
    conditionalOperation(
      'events.observe',
      'Visible stream-json text is mirrored; thinking and tool internals are excluded.',
    ),
    conditionalOperation('interrupt', 'Available while the Mu-launched CLI process is active.'),
    conditionalOperation('resume', 'Requires a persisted Claude Code session ID.'),
    unsupportedOperation('approval.resolve'),
    unsupportedOperation('artifact.list'),
    supportedOperation('artifact.submit'),
    conditionalOperation('task_lease.accept', 'Requires an active endpoint.'),
    conditionalOperation('task_lease.renew', 'Requires an active endpoint.'),
    supportedOperation('project_event.publish'),
    supportedOperation('task.complete'),
    supportedOperation('task.fail'),
    conditionalOperation(
      'context.search',
      'Requires the exact active Runtime binding and Run, plus a governed Context Pack with a delivered receipt.',
    ),
    conditionalOperation(
      'context.get_record',
      'Requires the exact active Runtime binding and Run, plus a governed Context Pack with a delivered receipt.',
    ),
  ],
  notes: [
    'Mu launches Claude Code print mode with structured stream-json output.',
    'The initial safety profile is read-only and never bypasses permission checks.',
  ],
})

const openWorker = createBuiltinRuntimeGatewayAdapter({
  adapterID: 'mu.runtime.openworker-sidecar',
  provider: OPEN_WORKER_PROVIDER,
  connectionKind: 'connected_agent',
  controlMode: 'attached',
  trustLevel: 'connected',
  observationFidelity: 'native_stream',
  declarations: [
    supportedOperation('history.discover'),
    supportedOperation('history.read'),
    conditionalOperation('session.create', 'Requires a verified loopback sidecar.'),
    conditionalOperation('session.attach', 'Requires an exact-workspace native session.'),
    conditionalOperation('input.submit', 'Requires an idle linked session.'),
    conditionalOperation('events.observe', 'Requires a verified session WebSocket.'),
    conditionalOperation('interrupt', 'Requires a live linked session.'),
    conditionalOperation('resume', 'Requires a persistent native session.'),
    conditionalOperation('approval.resolve', 'Requires a pending native Inbox request.'),
    conditionalOperation('artifact.list', 'Requires a verified exact-workspace session.'),
    supportedOperation('artifact.submit'),
    conditionalOperation('task_lease.accept', 'Requires an active endpoint.'),
    conditionalOperation('task_lease.renew', 'Requires a live binding heartbeat.'),
    supportedOperation('project_event.publish'),
    supportedOperation('task.complete'),
    supportedOperation('task.fail'),
    conditionalOperation(
      'context.search',
      'Requires the exact active Runtime binding and Run, plus a governed Context Pack with a delivered receipt.',
    ),
    conditionalOperation(
      'context.get_record',
      'Requires the exact active Runtime binding and Run, plus a governed Context Pack with a delivered receipt.',
    ),
  ],
  notes: [
    'OpenWorker Desktop owns its process; Mu attaches to the verified local sidecar.',
    'Workspace, session identity, approvals, and artifacts are validated before use.',
  ],
})

const BUILTIN_ADAPTERS: Record<string, RuntimeGatewayAdapter> = {
  [codexRuntimeTypeID]: codex,
  [claudeCodeRuntimeTypeID]: claudeCode,
  [openWorkerRuntimeTypeID]: openWorker,
}

export function adapterFor(endpoint: RuntimeEndpoint): RuntimeGatewayAdapter | undefined {
  return BUILTIN_ADAPTERS[endpoint.runtimeTypeID]
}

/**
 * Capability manifest for any endpoint. Builtin adapters declare their
 * operations; unknown endpoints get an all-unsupported "unimplemented" manifest.
 */
export function manifestFor(endpoint: RuntimeEndpoint): RuntimeGatewayManifest {
  const adapter = adapterFor(endpoint)
  if (adapter !== undefined) {
    return adapter.manifestFor(endpoint)
  }
  const identity = resolvedInstanceIdentity(endpoint)
  return {
    contractVersion: 1,
    adapterID: 'mu.runtime.unimplemented',
    provider: identity.provider,
    connectionKind: 'tool_host',
    controlMode: endpoint.provenance === 'artifact_only' ? 'submit_only' : 'history_only',
    trustLevel: 'submit_only',
    observationFidelity: 'none',
    operations: ALL_RUNTIME_GATEWAY_OPERATIONS.map((op) => unsupportedOperation(op)),
    instanceIdentity: identity,
    notes: ['No compiled Gateway adapter is registered for this endpoint.'],
  }
}

/** Throws MuError.capabilityMissing when an endpoint cannot serve an operation. */
export function requireOperation(
  operation: RuntimeGatewayOperation,
  endpoint: RuntimeEndpoint,
): void {
  const manifest = manifestFor(endpoint)
  const declaration = manifest.operations.find((o) => o.operation === operation)
  const supported =
    declaration?.support === 'supported' ||
    (declaration?.support === 'conditional' && endpoint.status === 'active')
  if (!supported) {
    const condition = declaration?.condition === undefined ? '' : ` ${declaration.condition}`
    throw MuError.capabilityMissing(
      `${endpoint.displayName} does not currently support ${runtimeGatewayOperationDisplayName(operation)}.${condition}`,
    )
  }
}

/** Convenience: does this endpoint currently support the operation? */
export function endpointSupports(
  operation: RuntimeGatewayOperation,
  endpoint: RuntimeEndpoint,
): boolean {
  return manifestFor(endpoint).operations.find((o) => o.operation === operation)?.support === 'supported'
    || (manifestFor(endpoint).operations.find((o) => o.operation === operation)?.support === 'conditional'
      && endpoint.status === 'active')
}
