import { nilIfEmpty, trimWhitespace } from '../hashing.ts'
import { uuid, type UUID } from '../identity.ts'

export const ContextTransitionAggregateKind = {
  source: 'source',
  record: 'record',
  conflict: 'conflict',
  importJob: 'import_job',
} as const
export type ContextTransitionAggregateKind =
  (typeof ContextTransitionAggregateKind)[keyof typeof ContextTransitionAggregateKind]

export const ContextTransitionKind = {
  created: 'created',
  stateChanged: 'state_changed',
  superseded: 'superseded',
  resolved: 'resolved',
  failed: 'failed',
} as const
export type ContextTransitionKind = (typeof ContextTransitionKind)[keyof typeof ContextTransitionKind]

/** Immutable audit receipt. The aggregate row can be rebuilt by replaying these. */
export interface ContextTransitionRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly aggregateKind: ContextTransitionAggregateKind
  readonly aggregateID: UUID
  readonly transitionKind: ContextTransitionKind
  readonly fromState?: string
  readonly toState: string
  readonly actorID: UUID
  readonly principalID: UUID
  readonly approvalID?: UUID
  readonly reviewID?: UUID
  readonly reason?: string
  readonly expectedRevision: number
  readonly newRevision: number
  readonly occurredAt: Date
}

export function createContextTransitionRecord(params: {
  id?: UUID
  projectID: UUID
  aggregateKind: ContextTransitionAggregateKind
  aggregateID: UUID
  transitionKind: ContextTransitionKind
  fromState?: string
  toState: string
  actorID: UUID
  principalID: UUID
  approvalID?: UUID
  reviewID?: UUID
  reason?: string
  expectedRevision: number
  newRevision: number
  occurredAt?: Date
}): ContextTransitionRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    aggregateKind: params.aggregateKind,
    aggregateID: params.aggregateID,
    transitionKind: params.transitionKind,
    fromState: params.fromState,
    toState: params.toState,
    actorID: params.actorID,
    principalID: params.principalID,
    approvalID: params.approvalID,
    reviewID: params.reviewID,
    reason: nilIfEmpty(trimWhitespace(params.reason ?? '')),
    expectedRevision: Math.max(0, params.expectedRevision),
    newRevision: Math.max(1, params.newRevision),
    occurredAt: params.occurredAt ?? new Date(),
  }
}
