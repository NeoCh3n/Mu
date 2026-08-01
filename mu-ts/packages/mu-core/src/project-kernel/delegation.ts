import { stableId, uuid, type UUID } from '../identity.ts'
import type { ProjectPermission } from './permissions.ts'

export const DelegationStatus = {
  active: 'active',
  revoked: 'revoked',
  expired: 'expired',
} as const
export type DelegationStatus = (typeof DelegationStatus)[keyof typeof DelegationStatus]

/** A Principal's explicit, Project-scoped authority grant to an Agent Actor. */
export interface DelegationRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly principalID: UUID
  readonly delegatedByActorID: UUID
  readonly agentActorID: UUID
  readonly taskID?: UUID
  readonly permissions: ReadonlySet<ProjectPermission>
  readonly restrictions: readonly string[]
  readonly status: DelegationStatus
  readonly expiresAt?: Date
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createDelegationRecord(params: {
  id?: UUID
  projectID: UUID
  principalID: UUID
  delegatedByActorID: UUID
  agentActorID: UUID
  taskID?: UUID
  permissions: ReadonlySet<ProjectPermission> | readonly ProjectPermission[]
  restrictions?: readonly string[]
  status?: DelegationStatus
  expiresAt?: Date
  createdAt?: Date
  updatedAt?: Date
}): DelegationRecord {
  const now = params.createdAt ?? new Date()
  const permissions = Array.isArray(params.permissions)
    ? new Set(params.permissions)
    : new Set(params.permissions)
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    principalID: params.principalID,
    delegatedByActorID: params.delegatedByActorID,
    agentActorID: params.agentActorID,
    taskID: params.taskID,
    permissions,
    restrictions: params.restrictions ?? [],
    status: params.status ?? 'active',
    expiresAt: params.expiresAt,
    createdAt: now,
    updatedAt: now,
  }
}

export function stableDelegationID(
  projectID: UUID,
  agentActorID: UUID,
  taskID?: UUID,
): UUID {
  return stableId('mu.delegation', [
    projectID.toLowerCase(),
    agentActorID.toLowerCase(),
    taskID?.toLowerCase() ?? 'project',
  ])
}

export function delegationIsActive(
  delegation: DelegationRecord,
  at: Date = new Date(),
): boolean {
  return (
    delegation.status === 'active' &&
    (delegation.expiresAt === undefined || delegation.expiresAt > at)
  )
}
