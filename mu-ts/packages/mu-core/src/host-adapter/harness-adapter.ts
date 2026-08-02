import { MuError } from '../errors.ts'
import type { Harness } from '../harness/types.ts'
import type {
  AgentHostAdapter,
  HostApprovalResolution,
  HostApprovalSupport,
  HostCapabilities,
} from './types.ts'
import type { AgentRuntimeEndpointScope } from '../types.ts'

// ---------------------------------------------------------------------------
// Harness → AgentHostAdapter
//
// Existing harnesses (LocalChildProcessHarness, QMHTTPHarness) implement the
// Phase 4 Harness protocol; this adapter exposes them through the stable
// AgentHostAdapter contract without touching their internals. New hosts
// implement AgentHostAdapter directly.
// ---------------------------------------------------------------------------

export interface HarnessAdapterOptions {
  readonly hostID?: string
  /** Defaults to 'report_only' — Mu resolves approvals internally. */
  readonly approvals?: HostApprovalSupport
  readonly deliveryReceipt?: boolean
  /** Host-side approval channel (only valid when approvals is resolveForward). */
  readonly resolveApproval?: (resolution: HostApprovalResolution) => Promise<void>
}

function defaultHostID(harness: Harness): string {
  switch (harness.capabilities.mode) {
    case 'qm':
      return 'qm.bridge'
    case 'local':
      return 'mu.local-harness'
  }
}

export function toAgentHostAdapter(
  harness: Harness,
  options: HarnessAdapterOptions = {},
): AgentHostAdapter {
  const approvals = options.approvals ?? 'report_only'
  if (approvals === 'resolve_forward' && options.resolveApproval === undefined) {
    throw MuError.invalidTransition(
      'HarnessAdapter: approvals=resolve_forward requires a resolveApproval implementation.',
    )
  }
  const capabilities: HostCapabilities = {
    ...harness.capabilities,
    approvals,
    deliveryReceipt: options.deliveryReceipt ?? false,
  }
  const adapter: AgentHostAdapter = {
    hostID: options.hostID ?? defaultHostID(harness),
    capabilities,
    probe: (scope) => harness.probeEndpoint?.(scope) ?? harness.probe(),
    submit: (scope, input, signal) => harness.runTurnForEndpoint?.(scope, input, signal)
      ?? harness.runTurn(input, signal),
    interrupt: (scope, sessionID) => harness.interruptForEndpoint?.(scope, sessionID)
      ?? harness.interrupt(sessionID),
    ...(options.resolveApproval !== undefined ? { resolveApproval: options.resolveApproval } : {}),
    listArtifacts: (scope, sessionID) => harness.listArtifactsForEndpoint?.(scope, sessionID)
      ?? harness.listArtifacts(sessionID),
    ...(typeof harness.discoverHistory === 'function' || typeof harness.discoverHistoryForEndpoint === 'function'
      ? {
          discoverHistory: (scope: AgentRuntimeEndpointScope, workspacePath: string) =>
            harness.discoverHistoryForEndpoint?.(scope, workspacePath)
              ?? harness.discoverHistory?.(workspacePath)
              ?? Promise.resolve([]),
        }
      : {}),
    ...(typeof harness.hydrateHistoryForEndpoint === 'function'
      ? { hydrateHistory: (scope: AgentRuntimeEndpointScope, candidate) => harness.hydrateHistoryForEndpoint!(scope, candidate) }
      : {}),
    ...(typeof harness.warmEndpoint === 'function'
      ? { warmEndpoint: (scope: AgentRuntimeEndpointScope) => harness.warmEndpoint!(scope) }
      : {}),
    ...('stop' in harness && typeof harness.stop === 'function'
      ? { stop: () => (harness as Harness & { stop: () => void }).stop() }
      : {}),
  }
  return adapter
}
