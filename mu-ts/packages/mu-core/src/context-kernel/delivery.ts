import { uuid, type UUID } from '../identity.ts'

export const ContextDeliveryStatus = {
  prepared: 'prepared',
  delivered: 'delivered',
  failed: 'failed',
} as const
export type ContextDeliveryStatus =
  (typeof ContextDeliveryStatus)[keyof typeof ContextDeliveryStatus]

/**
 * One immutable receipt per external turn delivery. A Runtime binding may
 * point at the latest Pack, but historical reconstruction uses this receipt.
 */
export interface ContextDeliveryReceipt {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID: UUID
  readonly contextPackID: UUID
  readonly runtimeBindingID: UUID
  readonly runID: UUID
  readonly endpointID: UUID
  readonly actorID: UUID
  readonly principalID: UUID
  readonly workspaceID: UUID
  readonly taskLeaseID?: UUID
  readonly leaseFencingToken?: number
  readonly contextRevision: string
  readonly policyRevision: string
  readonly packContentSHA256: string
  readonly status: ContextDeliveryStatus
  readonly adapterReceiptSHA256?: string
  readonly failureCode?: string
  readonly preparedAt: Date
  readonly completedAt?: Date
}

export function createContextDeliveryReceipt(params: {
  id?: UUID
  projectID: UUID
  taskID: UUID
  contextPackID: UUID
  runtimeBindingID: UUID
  runID: UUID
  endpointID: UUID
  actorID: UUID
  principalID: UUID
  workspaceID: UUID
  taskLeaseID?: UUID
  leaseFencingToken?: number
  contextRevision: string
  policyRevision: string
  packContentSHA256: string
  status: ContextDeliveryStatus
  adapterReceiptSHA256?: string
  failureCode?: string
  preparedAt?: Date
  completedAt?: Date
}): ContextDeliveryReceipt {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    contextPackID: params.contextPackID,
    runtimeBindingID: params.runtimeBindingID,
    runID: params.runID,
    endpointID: params.endpointID,
    actorID: params.actorID,
    principalID: params.principalID,
    workspaceID: params.workspaceID,
    taskLeaseID: params.taskLeaseID,
    leaseFencingToken: params.leaseFencingToken,
    contextRevision: params.contextRevision,
    policyRevision: params.policyRevision,
    packContentSHA256: params.packContentSHA256,
    status: params.status,
    adapterReceiptSHA256: params.adapterReceiptSHA256,
    failureCode: params.failureCode,
    preparedAt: params.preparedAt ?? new Date(),
    completedAt: params.completedAt,
  }
}
