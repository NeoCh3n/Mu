import { uuid, type UUID } from '../identity.ts'

export const ContextRelationType = {
  supports: 'supports',
  contradicts: 'contradicts',
  supersedes: 'supersedes',
  derivedFrom: 'derived_from',
  dependsOn: 'depends_on',
  implements: 'implements',
  reviews: 'reviews',
  references: 'references',
} as const
export type ContextRelationType = (typeof ContextRelationType)[keyof typeof ContextRelationType]

export interface ContextRelationRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly fromRecordID: UUID
  readonly toRecordID: UUID
  readonly relationType: ContextRelationType
  readonly createdByActorID: UUID
  readonly createdAt: Date
}

export function createContextRelationRecord(params: {
  id?: UUID
  projectID: UUID
  fromRecordID: UUID
  toRecordID: UUID
  relationType: ContextRelationType
  createdByActorID: UUID
  createdAt?: Date
}): ContextRelationRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    fromRecordID: params.fromRecordID,
    toRecordID: params.toRecordID,
    relationType: params.relationType,
    createdByActorID: params.createdByActorID,
    createdAt: params.createdAt ?? new Date(),
  }
}
