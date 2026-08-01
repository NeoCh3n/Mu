import { stableId, uuid, type UUID } from '../identity.ts'
import type { ContextAccessPolicyRecord, ContextPolicySubjectKind } from './policy.ts'
import type { ContextSensitivity } from './record.ts'

export const ContextPackItemKind = {
  record: 'record',
  artifact: 'artifact',
  conflict: 'conflict',
  projectFact: 'project_fact',
} as const
export type ContextPackItemKind = (typeof ContextPackItemKind)[keyof typeof ContextPackItemKind]

export interface ContextPolicyReceipt {
  readonly policyID: UUID
  readonly subjectKind: ContextPolicySubjectKind
  readonly subjectID: UUID
  readonly version: number
  readonly policySHA256: string
  readonly sensitivity: ContextSensitivity
}

export function contextPolicyReceipt(policy: ContextAccessPolicyRecord): ContextPolicyReceipt {
  return {
    policyID: policy.id,
    subjectKind: policy.subjectKind,
    subjectID: policy.subjectID,
    version: policy.version,
    policySHA256: policy.policySHA256,
    sensitivity: policy.sensitivity,
  }
}

export interface ContextPackItemRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly packID: UUID
  readonly itemKind: ContextPackItemKind
  readonly referencedID: UUID
  readonly sourceID?: UUID
  readonly inclusionReason: string
  readonly ordinal: number
  readonly renderedSHA256: string
  readonly referencedVersion?: number
  readonly referencedSHA256: string
  readonly referencedURI?: string
  readonly policyReceipts: readonly ContextPolicyReceipt[]
}

export function createContextPackItemRecord(params: {
  id?: UUID
  projectID: UUID
  packID: UUID
  itemKind: ContextPackItemKind
  referencedID: UUID
  sourceID?: UUID
  inclusionReason: string
  ordinal: number
  renderedSHA256: string
  referencedVersion?: number
  referencedSHA256: string
  referencedURI?: string
  policyReceipts: readonly ContextPolicyReceipt[]
}): ContextPackItemRecord {
  const id =
    params.id ??
    stableId('mu.context-pack-item', [
      params.packID.toLowerCase(),
      String(params.ordinal),
      params.itemKind,
      params.referencedID.toLowerCase(),
    ])
  return {
    id,
    projectID: params.projectID,
    packID: params.packID,
    itemKind: params.itemKind,
    referencedID: params.referencedID,
    sourceID: params.sourceID,
    inclusionReason: params.inclusionReason,
    ordinal: params.ordinal,
    renderedSHA256: params.renderedSHA256,
    referencedVersion: params.referencedVersion,
    referencedSHA256: params.referencedSHA256,
    referencedURI: params.referencedURI,
    policyReceipts: sortPolicyReceipts(params.policyReceipts),
  }
}

/** Swift ordering: subjectKind rawValue, then subjectID, then version. */
function sortPolicyReceipts(receipts: readonly ContextPolicyReceipt[]): readonly ContextPolicyReceipt[] {
  return [...new Map(receipts.map((r) => [policyReceiptKey(r), r])).values()].sort((a, b) => {
    if (a.subjectKind !== b.subjectKind) return a.subjectKind < b.subjectKind ? -1 : 1
    if (a.subjectID !== b.subjectID) return a.subjectID < b.subjectID ? -1 : 1
    return a.version - b.version
  })
}

function policyReceiptKey(r: ContextPolicyReceipt): string {
  return `${r.policyID}:${r.subjectKind}:${r.subjectID}:${r.version}`
}
