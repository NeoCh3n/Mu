import type { Harness } from '../harness/types.ts'
import type { UUID } from '../identity.ts'
import type { RuntimeEndpoint } from '../models.ts'
import { toAgentHostAdapter } from '../host-adapter/harness-adapter.ts'
import type { AgentRuntimeEndpointScope } from '../types.ts'
import {
  fetchEndpoints,
  upsertEndpoint,
  upsertRuntimeAdapterRegistration,
} from '../persistence/domain.ts'
import {
  createRuntimeAdapterRegistration,
} from '../runtime-gateway/manifest.ts'
import type { SQLiteStore } from '../persistence/store.ts'
import { appendLedger } from './ledger.ts'

export interface EndpointProbeOutcome {
  readonly endpointID: UUID
  readonly ok: boolean
  readonly runtimeVersion?: string
  readonly loggedIn?: boolean
  readonly message: string
  readonly latencyMilliseconds: number
}

/**
 * Probes every registered endpoint through the harness and persists the
 * outcome: endpoint status (active/offline/degraded), a fresh adapter
 * registration snapshot, and a ledger event. Mirrors the Swift probes.
 */
export async function probeEndpoints(
  store: SQLiteStore,
  harness: Harness,
  now: () => Date = () => new Date(),
): Promise<EndpointProbeOutcome[]> {
  const outcomes: EndpointProbeOutcome[] = []
  const host = toAgentHostAdapter(harness)
  for (const endpoint of fetchEndpoints(store)) {
    const scope: AgentRuntimeEndpointScope = {
      endpointID: endpoint.id,
      runtimeTypeID: endpoint.runtimeTypeID,
      displayName: endpoint.displayName,
      instanceIdentity: endpoint.instanceIdentity ?? {
        provider: { rawValue: endpoint.nativeConfiguration?.['provider'] ?? 'claude_code' },
        surfaceKind: endpoint.location === 'local' ? 'terminal_cli' : 'remote_service',
        identityBasis: 'endpoint_fallback',
        stableInstanceKey: `endpoint:${endpoint.id}`,
        instanceLabel: endpoint.displayName,
      },
    }
    const result = await host.probe(scope)
    const probedAt = now()
    const status: RuntimeEndpoint['status'] = result.ok ? 'active' : 'offline'
    const updated: RuntimeEndpoint = { ...endpoint, status, lastProbedAt: probedAt }
    upsertEndpoint(store, updated)

    const registration = createRuntimeAdapterRegistration({
      endpointID: endpoint.id,
      manifest: {
        contractVersion: 1,
        adapterID: `mu.${endpoint.runtimeTypeID}`,
        provider: { rawValue: endpoint.nativeConfiguration?.['provider'] ?? 'claude_code' },
        connectionKind: 'managed_runtime',
        controlMode: harness.capabilities.controlMode,
        trustLevel: 'managed',
        observationFidelity: harness.capabilities.observationFidelity,
        operations: [
          { operation: 'session.create', support: 'supported' },
          { operation: 'input.submit', support: 'supported' },
          { operation: 'events.observe', support: harness.capabilities.supportsEventStream ? 'supported' : 'unsupported' },
          { operation: 'interrupt', support: harness.capabilities.supportsInterrupt ? 'supported' : 'unsupported' },
          { operation: 'artifact.list', support: harness.capabilities.supportsArtifacts ? 'supported' : 'unsupported' },
        ],
        instanceIdentity: scope.instanceIdentity,
        notes: [],
      },
      probedAt,
    })
    upsertRuntimeAdapterRegistration(store, registration)

    appendLedger(store, {
      type: 'endpoint.probed',
      summary: result.ok
        ? `${endpoint.displayName} is active (${result.message}).`
        : `${endpoint.displayName} is offline (${result.message}).`,
      payload: { ok: String(result.ok), latencyMilliseconds: String(result.latencyMilliseconds) },
      occurredAt: probedAt,
    })
    outcomes.push({ ...result, endpointID: endpoint.id })
  }
  return outcomes
}
