import { stableId, uuid, type UUID } from '../identity.ts'

export const ProjectActorKind = {
  human: 'human',
  agent: 'agent',
} as const
export type ProjectActorKind = (typeof ProjectActorKind)[keyof typeof ProjectActorKind]

export const ProjectActorStatus = {
  active: 'active',
  suspended: 'suspended',
  retired: 'retired',
} as const
export type ProjectActorStatus =
  (typeof ProjectActorStatus)[keyof typeof ProjectActorStatus]

/**
 * A first-class Project participant. Runtime instance identity remains
 * separate and can change without changing this durable Actor identity.
 */
export interface ProjectActorRecord {
  readonly id: UUID
  readonly principalID: UUID
  readonly kind: ProjectActorKind
  readonly displayName: string
  readonly agentIdentityID?: UUID
  readonly runtimeEndpointID?: UUID
  readonly status: ProjectActorStatus
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createProjectActorRecord(params: {
  id?: UUID
  principalID: UUID
  kind: ProjectActorKind
  displayName: string
  agentIdentityID?: UUID
  runtimeEndpointID?: UUID
  status?: ProjectActorStatus
  createdAt?: Date
  updatedAt?: Date
}): ProjectActorRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    principalID: params.principalID,
    kind: params.kind,
    displayName: params.displayName,
    agentIdentityID: params.agentIdentityID,
    runtimeEndpointID: params.runtimeEndpointID,
    status: params.status ?? 'active',
    createdAt: now,
    updatedAt: now,
  }
}

export function stableRuntimeActorID(endpointID: UUID): UUID {
  return stableId('mu.actor.runtime', [endpointID.toLowerCase()])
}

export function stableAgentIdentityActorID(agentIdentityID: UUID): UUID {
  return stableId('mu.actor.agent-identity', [agentIdentityID.toLowerCase()])
}
