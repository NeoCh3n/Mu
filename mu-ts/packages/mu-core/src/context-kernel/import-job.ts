import { uuid, type UUID } from '../identity.ts'
import type { ConversationProvider } from '../types.ts'

export const ContextImportJobStatus = {
  received: 'received',
  validating: 'validating',
  importing: 'importing',
  completed: 'completed',
  failed: 'failed',
  rejected: 'rejected',
} as const
export type ContextImportJobStatus =
  (typeof ContextImportJobStatus)[keyof typeof ContextImportJobStatus]

export function contextImportJobStatusIsTerminal(status: ContextImportJobStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'rejected'
}

export function contextImportJobStatusAllowsTransition(
  from: ContextImportJobStatus,
  to: ContextImportJobStatus,
): boolean {
  switch (from) {
    case 'received':
      return to === 'validating' || to === 'rejected' || to === 'failed'
    case 'validating':
      return to === 'importing' || to === 'rejected' || to === 'failed'
    case 'importing':
      return to === 'completed' || to === 'failed'
    default:
      return false
  }
}

export interface ContextImportIssue {
  readonly code: string
  readonly message: string
}

export function createContextImportIssue(code: string, message: string): ContextImportIssue {
  return { code, message }
}

export interface ContextImportJobRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly sourceActorID: UUID
  readonly sourcePrincipalID?: UUID
  readonly runtimeProvider?: ConversationProvider
  readonly runtimeSessionID?: string
  readonly externalBundleID?: string
  readonly bundleChecksum: string
  readonly idempotencyKey: string
  readonly status: ContextImportJobStatus
  readonly progress: number
  readonly sourceID?: UUID
  readonly recordIDs: readonly UUID[]
  readonly issues: readonly ContextImportIssue[]
  readonly createdAt: Date
  readonly updatedAt: Date
  readonly completedAt?: Date
  readonly revision: number
}

export function createContextImportJobRecord(params: {
  id?: UUID
  projectID: UUID
  sourceActorID: UUID
  sourcePrincipalID?: UUID
  runtimeProvider?: ConversationProvider
  runtimeSessionID?: string
  externalBundleID?: string
  bundleChecksum: string
  idempotencyKey: string
  status?: ContextImportJobStatus
  progress?: number
  sourceID?: UUID
  recordIDs?: readonly UUID[]
  issues?: readonly ContextImportIssue[]
  createdAt?: Date
  updatedAt?: Date
  completedAt?: Date
  revision?: number
}): ContextImportJobRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    sourceActorID: params.sourceActorID,
    sourcePrincipalID: params.sourcePrincipalID,
    runtimeProvider: params.runtimeProvider,
    runtimeSessionID: params.runtimeSessionID,
    externalBundleID: params.externalBundleID,
    bundleChecksum: params.bundleChecksum,
    idempotencyKey: params.idempotencyKey,
    status: params.status ?? 'received',
    progress: Math.min(1, Math.max(0, params.progress ?? 0)),
    sourceID: params.sourceID,
    recordIDs: params.recordIDs ?? [],
    issues: params.issues ?? [],
    createdAt: now,
    updatedAt: params.updatedAt ?? now,
    completedAt: params.completedAt,
    revision: Math.max(1, params.revision ?? 1),
  }
}
