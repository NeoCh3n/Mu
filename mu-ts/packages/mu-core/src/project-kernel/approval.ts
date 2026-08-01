import { uuid, type UUID } from '../identity.ts'

export const ProjectApprovalDecision = {
  pending: 'pending',
  granted: 'granted',
  denied: 'denied',
  expired: 'expired',
  revoked: 'revoked',
} as const
export type ProjectApprovalDecision =
  (typeof ProjectApprovalDecision)[keyof typeof ProjectApprovalDecision]

export interface ProjectApprovalRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID?: UUID
  readonly runtimeInteractionID?: UUID
  readonly requestedByActorID: UUID
  readonly approverActorID?: UUID
  readonly scope: string
  readonly decision: ProjectApprovalDecision
  readonly reason?: string
  readonly createdAt: Date
  readonly resolvedAt?: Date
  readonly expiresAt?: Date
}

export function createProjectApprovalRecord(params: {
  id?: UUID
  projectID: UUID
  taskID?: UUID
  runtimeInteractionID?: UUID
  requestedByActorID: UUID
  approverActorID?: UUID
  scope: string
  decision?: ProjectApprovalDecision
  reason?: string
  createdAt?: Date
  resolvedAt?: Date
  expiresAt?: Date
}): ProjectApprovalRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    runtimeInteractionID: params.runtimeInteractionID,
    requestedByActorID: params.requestedByActorID,
    approverActorID: params.approverActorID,
    scope: params.scope,
    decision: params.decision ?? 'pending',
    reason: params.reason,
    createdAt: params.createdAt ?? new Date(),
    resolvedAt: params.resolvedAt,
    expiresAt: params.expiresAt,
  }
}
