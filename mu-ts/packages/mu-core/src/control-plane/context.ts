import { MuError } from '../errors.ts'
import { sha256Hex } from '../hashing.ts'
import type { UUID } from '../identity.ts'
import type {
  ContextConflictRecord,
  ContextDeliveryReceipt,
  ContextRecord,
  ContextSourceRecord,
} from '../context-kernel/index.ts'
import {
  createContextConflictRecord,
  createContextDeliveryReceipt,
  contextRecordStatusAllowsTransition,
} from '../context-kernel/index.ts'
import { createContextPackItemRecord, type ContextPackItemRecord } from '../context-kernel/pack-item.ts'
import type { SQLiteStore } from '../persistence/store.ts'
import { createProjectContextPackRecord, type ProjectContextPackRecord } from '../project-kernel/index.ts'

// ---------------------------------------------------------------------------
// Context-kernel record persistence. The SQLite schema (Phase 2) has the
// Swift-compatible context tables; these helpers map the kernel records into
// the generic `records` table with the Swift kind strings.
// ---------------------------------------------------------------------------

export const CONTEXT_KIND = {
  source: 'context_source',
  record: 'context_record',
  relation: 'context_relation',
  conflict: 'context_conflict',
  deliveryReceipt: 'context_delivery_receipt',
  packItem: 'context_pack_item',
} as const

// -- Sources ----------------------------------------------------------------

export function fetchContextSources(store: SQLiteStore, projectID?: UUID): ContextSourceRecord[] {
  const sources = store.fetchRecords<ContextSourceRecord>(CONTEXT_KIND.source)
  return projectID === undefined
    ? sources
    : sources.filter((s) => s.projectID === projectID)
}

export function upsertContextSource(store: SQLiteStore, source: ContextSourceRecord): void {
  store.upsertRecord({
    kind: CONTEXT_KIND.source,
    id: source.id,
    sortAt: source.importedAt,
    value: source,
  })
}

// -- Records ----------------------------------------------------------------

export function fetchContextRecords(store: SQLiteStore, projectID?: UUID): ContextRecord[] {
  const records = store.fetchRecords<ContextRecord>(CONTEXT_KIND.record)
  return projectID === undefined
    ? records
    : records.filter((r) => r.projectID === projectID)
}

export function fetchContextRecord(store: SQLiteStore, id: UUID): ContextRecord | undefined {
  return store.fetchRecord<ContextRecord>(CONTEXT_KIND.record, id)
}

export function upsertContextRecord(store: SQLiteStore, record: ContextRecord): void {
  store.upsertRecord({
    kind: CONTEXT_KIND.record,
    id: record.id,
    taskID: record.scope.taskID,
    sortAt: record.statusUpdatedAt ?? record.createdAt,
    value: record,
  })
}

/** Accepted records whose validity overlaps the given task's scope. */
export function acceptedContextRecordsForTask(
  store: SQLiteStore,
  projectID: UUID,
  taskID: UUID,
): ContextRecord[] {
  return fetchContextRecords(store, projectID).filter(
    (r) => r.status === 'accepted' && r.scope.taskID === taskID,
  )
}

/** Transitions a record; throws unless the kernel allows the transition. */
export function transitionContextRecordStatus(
  store: SQLiteStore,
  recordID: UUID,
  to: ContextRecord['status'],
  actorID: UUID,
  now: Date,
): ContextRecord {
  const record = fetchContextRecord(store, recordID)
  if (record === undefined) {
    throw MuError.recordNotFound(`Context record ${recordID} was not found.`)
  }
  if (record.status === to) return record
  if (!contextRecordStatusAllowsTransition(record.status, to)) {
    throw MuError.invalidTransition(
      `Context record ${record.status} cannot transition to ${to}.`,
    )
  }
  const updated: ContextRecord = {
    ...record,
    status: to,
    statusUpdatedAt: now,
    statusUpdatedByActorID: actorID,
  }
  upsertContextRecord(store, updated)
  return updated
}

// -- Conflicts --------------------------------------------------------------

export function fetchContextConflicts(store: SQLiteStore, projectID?: UUID): ContextConflictRecord[] {
  const conflicts = store.fetchRecords<ContextConflictRecord>(CONTEXT_KIND.conflict)
  return projectID === undefined
    ? conflicts
    : conflicts.filter((c) => c.projectID === projectID)
}

export function upsertContextConflict(store: SQLiteStore, conflict: ContextConflictRecord): void {
  store.upsertRecord({
    kind: CONTEXT_KIND.conflict,
    id: conflict.id,
    sortAt: conflict.createdAt,
    value: conflict,
  })
}

// -- Delivery receipts ------------------------------------------------------

export function fetchContextDeliveryReceipts(store: SQLiteStore, taskID?: UUID): ContextDeliveryReceipt[] {
  return taskID === undefined
    ? store.fetchRecords<ContextDeliveryReceipt>(CONTEXT_KIND.deliveryReceipt)
    : store.fetchRecordsForTask<ContextDeliveryReceipt>(CONTEXT_KIND.deliveryReceipt, taskID)
}

export function insertContextDeliveryReceipt(store: SQLiteStore, receipt: ContextDeliveryReceipt): void {
  store.insertImmutableRecord({
    kind: CONTEXT_KIND.deliveryReceipt,
    id: receipt.id,
    taskID: receipt.taskID,
    sortAt: receipt.preparedAt,
    value: receipt,
  })
}

// -- Pack items -------------------------------------------------------------

export function fetchContextPackItems(store: SQLiteStore, packID: UUID): ContextPackItemRecord[] {
  return store
    .fetchRecords<ContextPackItemRecord>(CONTEXT_KIND.packItem)
    .filter((item) => item.packID === packID)
    .sort((a, b) => a.ordinal - b.ordinal)
}

export function insertContextPackItem(store: SQLiteStore, item: ContextPackItemRecord): void {
  store.insertImmutableRecord({
    kind: CONTEXT_KIND.packItem,
    id: item.id,
    sortAt: new Date(0),
    value: item,
  })
}

// ---------------------------------------------------------------------------
// Pack building
// ---------------------------------------------------------------------------

export interface BuildContextPackParams {
  readonly projectID: UUID
  readonly taskID: UUID
  readonly workspaceID: UUID
  readonly objective: string
  readonly endpointID: UUID
  readonly bindingID: UUID
  readonly actorID: UUID
  readonly principalID?: UUID
  readonly taskLeaseID?: UUID
  readonly leaseFencingToken?: number
  readonly constraints?: readonly string[]
  readonly relevantFilePaths?: readonly string[]
  readonly acceptedArtifactIDs?: readonly UUID[]
  readonly createdAt?: Date
}

/**
 * Builds an immutable Project Context Pack from the task's accepted context
 * records, mirroring the Swift ContextKernel pack construction: every pack
 * carries a SHA-256 of its rendered markdown so the runtime can verify the
 * delivered contract byte-for-byte.
 */
export function buildProjectContextPack(
  store: SQLiteStore,
  params: BuildContextPackParams,
): ProjectContextPackRecord {
  const accepted = acceptedContextRecordsForTask(store, params.projectID, params.taskID)
  const rendered = renderPackMarkdown(params.objective, accepted, params.constraints ?? [])

  const pack = createProjectContextPackRecord({
    projectID: params.projectID,
    taskID: params.taskID,
    workspaceID: params.workspaceID,
    objective: params.objective,
    relevantFilePaths: params.relevantFilePaths ?? [],
    acceptedArtifactIDs: params.acceptedArtifactIDs ?? [],
    constraints: params.constraints ?? [],
    actorID: params.actorID,
    principalID: params.principalID,
    runtimeEndpointID: params.endpointID,
    runtimeBindingID: params.bindingID,
    taskLeaseID: params.taskLeaseID,
    leaseFencingToken: params.leaseFencingToken,
    contextRevision: `rev-${params.taskID.toLowerCase()}-${accepted.length}`,
    policyRevision: '1',
    includedContextRecordIDs: accepted.map((r) => r.id),
    renderedContextMarkdown: rendered,
    contentSHA256: sha256Hex(rendered),
    createdAt: params.createdAt,
  })

  // One immutable pack item per included record (deterministic by ordinal).
  accepted.forEach((record, index) => {
    insertContextPackItem(
      store,
      createContextPackItemRecord({
        projectID: params.projectID,
        packID: pack.id,
        itemKind: 'record',
        referencedID: record.id,
        sourceID: record.sourceID,
        inclusionReason: 'accepted task context',
        ordinal: index,
        renderedSHA256: sha256Hex(record.value.type === 'string' ? record.value.value : ''),
        referencedSHA256: record.contentSHA256,
        policyReceipts: [],
      }),
    )
  })
  return pack
}

export function createDeliveryReceipt(
  store: SQLiteStore,
  params: Omit<Parameters<typeof createContextDeliveryReceipt>[0], 'id' | 'principalID'> & { readonly principalID?: UUID },
): ContextDeliveryReceipt {
  const receipt = createContextDeliveryReceipt({
    ...params,
    principalID: params.principalID ?? params.actorID,
  })
  insertContextDeliveryReceipt(store, receipt)
  return receipt
}

// ---------------------------------------------------------------------------
// Rendering (canonical markdown, verified by contentSHA256)
// ---------------------------------------------------------------------------

export function renderPackMarkdown(
  objective: string,
  records: readonly ContextRecord[],
  constraints: readonly string[],
): string {
  const sections: string[] = []
  sections.push(`## Objective\n\n${objective}`)
  if (records.length > 0) {
    sections.push(`## Accepted Context (${records.length})`)
    for (const record of records) {
      sections.push(
        `- [${record.kind}] ${record.subject ?? 'untitled'} (${record.id}): ${valueText(record.value)}`,
      )
    }
  }
  if (constraints.length > 0) {
    sections.push(`## Constraints\n\n${constraints.map((c) => `- ${c}`).join('\n')}`)
  }
  return sections.join('\n\n')
}

function valueText(value: ContextRecord['value']): string {
  switch (value.type) {
    case 'string':
      return value.value
    case 'number':
      return String(value.value)
    case 'bool':
      return String(value.value)
    case 'object':
      return JSON.stringify(value.value)
    case 'array':
      return JSON.stringify(value.value)
    case 'null':
      return 'null'
    default:
      return ''
  }
}
