import type { UUID } from '../identity.ts'
import type {
  ContextConflictRecord,
} from './conflict.ts'
import type { ContextImportJobRecord } from './import-job.ts'
import type { ContextRecord, ContextRecordStatus, ContextSensitivity, ContextSourceRecord, ContextSourceState } from './record.ts'

/** A record + source + match reason tuple. */
export interface ContextSearchResult {
  readonly record: ContextRecord
  readonly source: ContextSourceRecord
  readonly matchReason: string
}

/** Metadata-only projection used to authorize a lookup before any payload read. */
export interface ContextSourceAccessHeader {
  readonly id: UUID
  readonly projectID: UUID
  readonly sourceActorID: UUID
  readonly sourcePrincipalID?: UUID
  readonly accessPolicyID: UUID
  readonly state: ContextSourceState
}

export interface ContextRecordAccessHeader {
  readonly id: UUID
  readonly projectID: UUID
  readonly sourceID: UUID
  readonly accessPolicyID: UUID
  readonly status: ContextRecordStatus
  readonly scopeTaskID?: UUID
  readonly sensitivity: ContextSensitivity
}

export interface ContextImportResult {
  readonly job: ContextImportJobRecord
  readonly source: ContextSourceRecord
  readonly records: readonly ContextRecord[]
  readonly conflicts: readonly ContextConflictRecord[]
  readonly wasIdempotentReplay: boolean
}
