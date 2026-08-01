import { stableId, uuid, type UUID } from '../identity.ts'
import { trimWhitespace } from '../hashing.ts'

export const ContextConflictType = {
  value: 'value',
  version: 'version',
  scope: 'scope',
  temporal: 'temporal',
  interpretation: 'interpretation',
} as const
export type ContextConflictType = (typeof ContextConflictType)[keyof typeof ContextConflictType]

export const ContextConflictStatus = {
  unresolved: 'unresolved',
  resolved: 'resolved',
  acceptedMultiple: 'accepted_multiple',
} as const
export type ContextConflictStatus =
  (typeof ContextConflictStatus)[keyof typeof ContextConflictStatus]

export function contextConflictStatusAllowsTransition(
  from: ContextConflictStatus,
  to: ContextConflictStatus,
): boolean {
  return from === 'unresolved' && (to === 'resolved' || to === 'accepted_multiple')
}

export interface ContextConflictRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly subject: string
  readonly recordIDs: readonly UUID[]
  readonly conflictType: ContextConflictType
  readonly status: ContextConflictStatus
  readonly resolvedByActorID?: UUID
  readonly acceptedRecordIDs: readonly UUID[]
  readonly resolutionNote?: string
  readonly createdAt: Date
  readonly resolvedAt?: Date
  readonly revision: number
}

export function createContextConflictRecord(params: {
  id?: UUID
  projectID: UUID
  subject: string
  recordIDs: readonly UUID[]
  conflictType?: ContextConflictType
  status?: ContextConflictStatus
  resolvedByActorID?: UUID
  acceptedRecordIDs?: readonly UUID[]
  resolutionNote?: string
  createdAt?: Date
  resolvedAt?: Date
  revision?: number
}): ContextConflictRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    subject: trimWhitespace(params.subject).toLowerCase(),
    recordIDs: sortedUniqueUUIDs(params.recordIDs),
    conflictType: params.conflictType ?? 'value',
    status: params.status ?? 'unresolved',
    resolvedByActorID: params.resolvedByActorID,
    acceptedRecordIDs: sortedUniqueUUIDs(params.acceptedRecordIDs ?? []),
    resolutionNote: params.resolutionNote,
    createdAt: params.createdAt ?? new Date(),
    resolvedAt: params.resolvedAt,
    revision: Math.max(1, params.revision ?? 1),
  }
}

export function stableConflictID(
  projectID: UUID,
  subject: string,
  recordIDs: readonly UUID[],
): UUID {
  return stableId('mu.context-conflict', [
    projectID.toLowerCase(),
    subject.toLowerCase(),
    ...recordIDs.map((id) => id.toLowerCase()).sort(),
  ])
}

export function sortedUniqueUUIDs(ids: readonly UUID[]): readonly UUID[] {
  return [...new Set(ids.map((id) => id.toLowerCase()))].sort() as UUID[]
}
