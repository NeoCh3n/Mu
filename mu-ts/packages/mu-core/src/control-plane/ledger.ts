import { uuid, type UUID } from '../identity.ts'
import { createLedgerEvent, type LedgerEvent } from '../models.ts'
import type { SQLiteStore } from '../persistence/store.ts'

/**
 * Ledger helpers. Every control-plane mutation appends an immutable event so
 * the server (Phase 6) can stream a live audit trail.
 */
export function appendLedger(
  store: SQLiteStore,
  params: {
    type: string
    summary: string
    projectID?: UUID
    actorID?: UUID
    principalID?: UUID
    workspaceID?: UUID
    taskID?: UUID
    runID?: UUID
    artifactID?: UUID
    reviewID?: UUID
    approvalID?: UUID
    correlationID?: UUID
    payload?: Readonly<Record<string, string>>
    causalParentID?: UUID
    occurredAt?: Date
  },
): LedgerEvent {
  const event = createLedgerEvent({
    id: params.correlationID ?? uuid(),
    schemaVersion: '1.0',
    projectID: params.projectID,
    actorID: params.actorID,
    principalID: params.principalID,
    workspaceID: params.workspaceID,
    artifactID: params.artifactID,
    reviewID: params.reviewID,
    approvalID: params.approvalID,
    correlationID: params.correlationID,
    taskID: params.taskID,
    runID: params.runID,
    type: params.type,
    summary: params.summary,
    payload: params.payload,
    causalParentID: params.causalParentID,
    occurredAt: params.occurredAt,
  })
  const sequence = store.appendEvent(event)
  return { ...event, sequence }
}

export function fetchLedger(store: SQLiteStore, taskID?: UUID, limit = 500): LedgerEvent[] {
  return store.fetchEvents(taskID, limit)
}
