import { ContextKernelValidationError } from '../errors.ts'
import { encodeMuJSON, nilIfEmpty, sha256Hex, trimWhitespace } from '../hashing.ts'
import { uuid, type UUID } from '../identity.ts'
import type { ConversationProvider } from '../types.ts'
import {
  CONTEXT_CANONICALIZATION_VERSION,
  contentSHA256,
  type ProjectContextValue,
} from './values.ts'

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

export const ContextSourceType = {
  agentExport: 'agent_export',
  runtimeSession: 'runtime_session',
  humanInput: 'human_input',
  artifact: 'artifact',
  repository: 'repository',
  externalSource: 'external_source',
} as const
export type ContextSourceType = (typeof ContextSourceType)[keyof typeof ContextSourceType]

export const ContextSourceState = {
  active: 'active',
  redacted: 'redacted',
  rejected: 'rejected',
} as const
export type ContextSourceState = (typeof ContextSourceState)[keyof typeof ContextSourceState]

export function contextSourceStateAllowsTransition(
  from: ContextSourceState,
  to: ContextSourceState,
): boolean {
  return from === 'active' && (to === 'redacted' || to === 'rejected')
}

/** Raw provenance. Large source bytes live in CAS and are referenced by URI. */
export interface ContextSourceRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly sourceType: ContextSourceType
  readonly sourceActorID: UUID
  readonly sourcePrincipalID?: UUID
  readonly runtimeEndpointID?: UUID
  readonly runtimeProvider?: ConversationProvider
  readonly runtimeSessionID?: string
  readonly externalRef?: string
  readonly sourceChecksum: string
  readonly checksumAlgorithm: string
  readonly sourceSchemaVersion?: string
  readonly rawArtifactURI?: string
  readonly accessPolicyID?: UUID
  readonly originalTimestamp?: Date
  readonly importedAt: Date
  readonly state: ContextSourceState
  readonly revision: number
}

export function createContextSourceRecord(params: {
  id?: UUID
  projectID: UUID
  sourceType: ContextSourceType
  sourceActorID: UUID
  sourcePrincipalID?: UUID
  runtimeEndpointID?: UUID
  runtimeProvider?: ConversationProvider
  runtimeSessionID?: string
  externalRef?: string
  sourceChecksum: string
  checksumAlgorithm?: string
  sourceSchemaVersion?: string
  rawArtifactURI?: string
  accessPolicyID?: UUID
  originalTimestamp?: Date
  importedAt?: Date
  state?: ContextSourceState
  revision?: number
}): ContextSourceRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    sourceType: params.sourceType,
    sourceActorID: params.sourceActorID,
    sourcePrincipalID: params.sourcePrincipalID,
    runtimeEndpointID: params.runtimeEndpointID,
    runtimeProvider: params.runtimeProvider,
    runtimeSessionID: params.runtimeSessionID,
    externalRef: params.externalRef,
    sourceChecksum: params.sourceChecksum,
    checksumAlgorithm: params.checksumAlgorithm ?? 'sha256',
    sourceSchemaVersion: params.sourceSchemaVersion,
    rawArtifactURI: params.rawArtifactURI,
    accessPolicyID: params.accessPolicyID,
    originalTimestamp: params.originalTimestamp,
    importedAt: params.importedAt ?? new Date(),
    state: params.state ?? 'active',
    revision: Math.max(1, params.revision ?? 1),
  }
}

// ---------------------------------------------------------------------------
// ContextRecord
// ---------------------------------------------------------------------------

export const ContextRecordKind = {
  fact: 'fact',
  requirement: 'requirement',
  decision: 'decision',
  constraint: 'constraint',
  assumption: 'assumption',
  finding: 'finding',
  artifactReference: 'artifact_ref',
  taskState: 'task_state',
} as const
export type ContextRecordKind = (typeof ContextRecordKind)[keyof typeof ContextRecordKind]

export const ContextRecordStatus = {
  candidate: 'candidate',
  accepted: 'accepted',
  disputed: 'disputed',
  superseded: 'superseded',
  rejected: 'rejected',
} as const
export type ContextRecordStatus = (typeof ContextRecordStatus)[keyof typeof ContextRecordStatus]

export function contextRecordStatusAllowsTransition(
  from: ContextRecordStatus,
  to: ContextRecordStatus,
): boolean {
  switch (from) {
    case 'candidate':
      return to === 'accepted' || to === 'rejected' || to === 'disputed'
    case 'accepted':
      return to === 'superseded' || to === 'disputed'
    case 'disputed':
      return to === 'accepted' || to === 'rejected' || to === 'superseded'
    default:
      return false
  }
}

export const ContextAuthority = {
  rawAgentOutput: 'raw_agent_output',
  agentClaim: 'agent_claim',
  toolVerified: 'tool_verified',
  humanReviewed: 'human_reviewed',
  projectApproved: 'project_approved',
  externalAuthority: 'external_authority',
} as const
export type ContextAuthority = (typeof ContextAuthority)[keyof typeof ContextAuthority]

export const ContextSensitivity = {
  public: 'public',
  project: 'project',
  restricted: 'restricted',
  secret: 'secret',
} as const
export type ContextSensitivity = (typeof ContextSensitivity)[keyof typeof ContextSensitivity]

const SENSITIVITY_RANK: Record<ContextSensitivity, number> = {
  public: 0,
  project: 1,
  restricted: 2,
  secret: 3,
}

export function sensitivityLessThan(a: ContextSensitivity, b: ContextSensitivity): boolean {
  return SENSITIVITY_RANK[a] < SENSITIVITY_RANK[b]
}

export interface ContextScope {
  readonly environment?: string
  readonly component?: string
  readonly taskID?: UUID
}

export function createContextScope(params: {
  environment?: string
  component?: string
  taskID?: UUID
}): ContextScope {
  return {
    environment: normalizedScopeDimension(params.environment),
    component: normalizedScopeDimension(params.component),
    taskID: params.taskID?.toLowerCase() as UUID | undefined,
  }
}

function normalizedScopeDimension(value: string | undefined): string | undefined {
  const normalized = trimWhitespace(value ?? '').toLowerCase()
  return normalized === '' ? undefined : normalized
}

export function scopeStableKey(scope: ContextScope): string {
  return [
    scope.environment ?? '*',
    scope.component ?? '*',
    scope.taskID?.toLowerCase() ?? '*',
  ].join('\u{1F}')
}

export function scopeOverlaps(a: ContextScope, b: ContextScope): boolean {
  return (
    dimensionOverlaps(a.environment, b.environment) &&
    dimensionOverlaps(a.component, b.component) &&
    (a.taskID === undefined || b.taskID === undefined || a.taskID === b.taskID)
  )
}

function dimensionOverlaps(a: string | undefined, b: string | undefined): boolean {
  return a === undefined || b === undefined || a === b
}

/**
 * A normalized claim. Payload, source, subject, scope, and checksum are
 * immutable after insert; only controlled lifecycle fields may transition.
 */
export interface ContextRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly sourceID: UUID
  readonly externalID?: string
  readonly kind: ContextRecordKind
  readonly subject?: string
  readonly value: ProjectContextValue
  readonly contentSHA256: string
  readonly immutableFingerprint: string
  readonly canonicalizationVersion: string
  readonly status: ContextRecordStatus
  readonly authority: ContextAuthority
  readonly scope: ContextScope
  readonly sensitivity: ContextSensitivity
  readonly accessPolicyID?: UUID
  readonly confidence?: number
  readonly validFrom?: Date
  readonly validUntil?: Date
  readonly createdByActorID: UUID
  readonly createdAt: Date
  readonly statusUpdatedAt: Date
  readonly statusUpdatedByActorID?: UUID
  readonly supersededByRecordID?: UUID
  readonly revision: number
}

export function createContextRecord(params: {
  id?: UUID
  projectID: UUID
  sourceID: UUID
  externalID?: string
  kind: ContextRecordKind
  subject?: string
  value: ProjectContextValue
  status?: ContextRecordStatus
  authority?: ContextAuthority
  scope?: ContextScope
  sensitivity?: ContextSensitivity
  accessPolicyID?: UUID
  confidence?: number
  validFrom?: Date
  validUntil?: Date
  createdByActorID: UUID
  createdAt?: Date
  statusUpdatedAt?: Date
  statusUpdatedByActorID?: UUID
  supersededByRecordID?: UUID
  revision?: number
}): ContextRecord {
  if (params.confidence !== undefined) {
    const c = params.confidence
    if (!Number.isFinite(c) || c < 0 || c > 1) {
      throw ContextKernelValidationError.invalidConfidence()
    }
  }
  if (params.validFrom !== undefined && params.validUntil !== undefined && params.validFrom >= params.validUntil) {
    throw ContextKernelValidationError.invalidValidityInterval()
  }
  const contentHash = contentSHA256(params.value)
  const externalID = nilIfEmpty(trimWhitespace(params.externalID ?? ''))
  const subject = nilIfEmpty(trimWhitespace(params.subject ?? '').toLowerCase())
  const createdAt = params.createdAt ?? new Date()
  const fingerprint = makeImmutableFingerprint({
    projectID: params.projectID,
    sourceID: params.sourceID,
    externalID,
    kind: params.kind,
    subject,
    contentSHA256: contentHash,
    scope: params.scope ?? {},
    sensitivity: params.sensitivity ?? 'project',
    accessPolicyID: params.accessPolicyID,
    confidence: params.confidence,
    validFrom: params.validFrom,
    validUntil: params.validUntil,
    createdByActorID: params.createdByActorID,
    createdAt,
  })
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    sourceID: params.sourceID,
    externalID,
    kind: params.kind,
    subject,
    value: params.value,
    contentSHA256: contentHash,
    immutableFingerprint: fingerprint,
    canonicalizationVersion: CONTEXT_CANONICALIZATION_VERSION,
    status: params.status ?? 'candidate',
    authority: params.authority ?? 'agent_claim',
    scope: params.scope ?? {},
    sensitivity: params.sensitivity ?? 'project',
    accessPolicyID: params.accessPolicyID,
    confidence: params.confidence,
    validFrom: params.validFrom,
    validUntil: params.validUntil,
    createdByActorID: params.createdByActorID,
    createdAt,
    statusUpdatedAt: params.statusUpdatedAt ?? createdAt,
    statusUpdatedByActorID: params.statusUpdatedByActorID,
    supersededByRecordID: params.supersededByRecordID,
    revision: Math.max(1, params.revision ?? 1),
  }
}

export function recordValidityOverlaps(a: ContextRecord, b: ContextRecord): boolean {
  const aStart = a.validFrom?.getTime() ?? -8_640_000_000_000_000
  const aEnd = a.validUntil?.getTime() ?? 8_640_000_000_000_000
  const bStart = b.validFrom?.getTime() ?? -8_640_000_000_000_000
  const bEnd = b.validUntil?.getTime() ?? 8_640_000_000_000_000
  return aStart < bEnd && bStart < aEnd
}

export function validateImmutableReceipt(record: ContextRecord): void {
  if (record.canonicalizationVersion !== CONTEXT_CANONICALIZATION_VERSION) {
    throw ContextKernelValidationError.unsupportedCanonicalizationVersion(
      record.canonicalizationVersion,
    )
  }
  const rebuiltContentHash = contentSHA256(record.value)
  const rebuiltFingerprint = makeImmutableFingerprint({
    projectID: record.projectID,
    sourceID: record.sourceID,
    externalID: record.externalID,
    kind: record.kind,
    subject: record.subject,
    contentSHA256: record.contentSHA256,
    scope: record.scope,
    sensitivity: record.sensitivity,
    accessPolicyID: record.accessPolicyID,
    confidence: record.confidence,
    validFrom: record.validFrom,
    validUntil: record.validUntil,
    createdByActorID: record.createdByActorID,
    createdAt: record.createdAt,
  })
  if (rebuiltContentHash !== record.contentSHA256 || rebuiltFingerprint !== record.immutableFingerprint) {
    throw ContextKernelValidationError.immutableFingerprintMismatch()
  }
}

interface ContextRecordFingerprintMaterial {
  projectID: UUID
  sourceID: UUID
  externalID?: string
  kind: ContextRecordKind
  subject?: string
  contentSHA256: string
  scope: ContextScope
  sensitivity: ContextSensitivity
  accessPolicyID?: UUID
  confidence?: number
  validFrom?: Date
  validUntil?: Date
  createdByActorID: UUID
  createdAt: Date
}

/** Byte-identical to Swift `ContextRecord.makeImmutableFingerprint`. */
export function makeImmutableFingerprint(material: ContextRecordFingerprintMaterial): string {
  const json = encodeMuJSON({
    schemaVersion: 1,
    canonicalizationVersion: CONTEXT_CANONICALIZATION_VERSION,
    projectID: material.projectID.toLowerCase(),
    sourceID: material.sourceID.toLowerCase(),
    externalID: material.externalID,
    kind: material.kind,
    subject: material.subject,
    contentSHA256: material.contentSHA256,
    scope: material.scope,
    sensitivity: material.sensitivity,
    accessPolicyID: material.accessPolicyID?.toLowerCase(),
    confidence: material.confidence,
    validFrom: material.validFrom,
    validUntil: material.validUntil,
    createdByActorID: material.createdByActorID.toLowerCase(),
    createdAt: material.createdAt,
  })
  return sha256Hex(json)
}
