import { uuid, type UUID } from '../identity.ts'

export const TaskLeaseState = {
  active: 'active',
  released: 'released',
  expired: 'expired',
  revoked: 'revoked',
} as const
export type TaskLeaseState = (typeof TaskLeaseState)[keyof typeof TaskLeaseState]

/**
 * A fencing-token-based lease. `fencingToken` monotonically increases per
 * task so stale holders cannot mutate state after the lease moves on.
 * Mirrors TaskLeaseRecord from ProjectKernel.swift.
 */
export interface TaskLeaseRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID: UUID
  readonly agentActorID: UUID
  readonly endpointID: UUID
  readonly runtimeBindingID?: UUID
  readonly fencingToken: number
  readonly state: TaskLeaseState
  readonly issuedAt: Date
  readonly expiresAt: Date
  readonly lastHeartbeatAt: Date
  readonly releasedAt?: Date
}

export function createTaskLeaseRecord(params: {
  id?: UUID
  projectID: UUID
  taskID: UUID
  agentActorID: UUID
  endpointID: UUID
  runtimeBindingID?: UUID
  fencingToken: number
  state?: TaskLeaseState
  issuedAt?: Date
  expiresAt: Date
  lastHeartbeatAt?: Date
  releasedAt?: Date
}): TaskLeaseRecord {
  const now = params.issuedAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    agentActorID: params.agentActorID,
    endpointID: params.endpointID,
    runtimeBindingID: params.runtimeBindingID,
    fencingToken: params.fencingToken,
    state: params.state ?? 'active',
    issuedAt: now,
    expiresAt: params.expiresAt,
    lastHeartbeatAt: params.lastHeartbeatAt ?? now,
    releasedAt: params.releasedAt,
  }
}

export function taskLeaseIsActive(
  lease: TaskLeaseRecord,
  at: Date = new Date(),
): boolean {
  return lease.state === 'active' && lease.expiresAt > at && lease.releasedAt === undefined
}
