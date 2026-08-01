import type { ConversationProvider } from '../types.ts'
import type { RuntimeEndpoint } from '../models.ts'
import { resolvedInstanceIdentity } from './identity.ts'
import type {
  AgentConnectionKind,
  AgentTrustLevel,
  RuntimeControlMode,
  RuntimeGatewayManifest,
  RuntimeGatewayOperationDeclaration,
  RuntimeObservationFidelity,
} from './manifest.ts'

/**
 * Extension point for a compiled local adapter or a future remote BYOA
 * connector. History is an optional facet rather than proof of live control.
 */
export interface RuntimeGatewayAdapter {
  readonly adapterID: string
  readonly provider: ConversationProvider

  manifestFor(endpoint: RuntimeEndpoint): RuntimeGatewayManifest
}

export interface BuiltinRuntimeGatewayAdapterParams {
  readonly adapterID: string
  readonly provider: ConversationProvider
  readonly connectionKind: AgentConnectionKind
  readonly controlMode: RuntimeControlMode
  readonly trustLevel: AgentTrustLevel
  readonly observationFidelity: RuntimeObservationFidelity
  readonly declarations: readonly RuntimeGatewayOperationDeclaration[]
  readonly notes?: readonly string[]
}

export function createBuiltinRuntimeGatewayAdapter(
  params: BuiltinRuntimeGatewayAdapterParams,
): RuntimeGatewayAdapter {
  return {
    adapterID: params.adapterID,
    provider: params.provider,
    manifestFor(endpoint: RuntimeEndpoint): RuntimeGatewayManifest {
      return {
        contractVersion: 1,
        adapterID: params.adapterID,
        provider: params.provider,
        connectionKind: params.connectionKind,
        controlMode: params.controlMode,
        trustLevel: params.trustLevel,
        observationFidelity: params.observationFidelity,
        operations: [...params.declarations].sort((a, b) =>
          a.operation < b.operation ? -1 : a.operation > b.operation ? 1 : 0,
        ),
        instanceIdentity: resolvedInstanceIdentity(endpoint),
        notes: params.notes ?? [],
      }
    },
  }
}
