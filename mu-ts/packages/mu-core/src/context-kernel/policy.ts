import { ContextKernelValidationError } from '../errors.ts'
import { encodeMuJSON, sha256Hex, trimWhitespace } from '../hashing.ts'
import { stableId, uuid, type UUID } from '../identity.ts'
import type { ContextSensitivity } from './record.ts'

export const ContextPolicySubjectKind = {
  source: 'source',
  record: 'record',
  artifact: 'artifact',
  pack: 'pack',
} as const
export type ContextPolicySubjectKind =
  (typeof ContextPolicySubjectKind)[keyof typeof ContextPolicySubjectKind]

export const ContextVisibility = {
  projectMembers: 'project_members',
  taskParticipants: 'task_participants',
  ownerOnly: 'owner_only',
  selectedActors: 'selected_actors',
} as const
export type ContextVisibility = (typeof ContextVisibility)[keyof typeof ContextVisibility]

export interface ContextAccessPolicyRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly subjectKind: ContextPolicySubjectKind
  readonly subjectID: UUID
  readonly familyID: UUID
  readonly version: number
  readonly supersedesPolicyID?: UUID
  readonly namespace: string
  readonly sensitivity: ContextSensitivity
  readonly visibility: ContextVisibility
  readonly allowedActorIDs: readonly UUID[]
  readonly allowedPrincipalIDs: readonly UUID[]
  readonly allowedTaskIDs: readonly UUID[]
  readonly createdByActorID: UUID
  readonly createdAt: Date
  readonly policySHA256: string
}

export function createContextAccessPolicyRecord(params: {
  id?: UUID
  projectID: UUID
  subjectKind: ContextPolicySubjectKind
  subjectID: UUID
  familyID?: UUID
  version?: number
  supersedesPolicyID?: UUID
  namespace?: string
  sensitivity?: ContextSensitivity
  visibility?: ContextVisibility
  allowedActorIDs?: readonly UUID[]
  allowedPrincipalIDs?: readonly UUID[]
  allowedTaskIDs?: readonly UUID[]
  createdByActorID: UUID
  createdAt?: Date
}): ContextAccessPolicyRecord {
  const namespace = trimWhitespace(params.namespace ?? 'project/shared').toLowerCase()
  const version = Math.max(1, params.version ?? 1)
  const familyID =
    params.familyID ??
    stableId('mu.context-policy-family', [
      params.projectID.toLowerCase(),
      params.subjectKind,
      params.subjectID.toLowerCase(),
    ])
  const actorIDs = sortedUniqueUUIDs(params.allowedActorIDs ?? [])
  const principalIDs = sortedUniqueUUIDs(params.allowedPrincipalIDs ?? [])
  const taskIDs = sortedUniqueUUIDs(params.allowedTaskIDs ?? [])
  const createdAt = params.createdAt ?? new Date()

  const policySHA256 = sha256Hex(
    encodeMuJSON({
      schemaVersion: 1,
      projectID: params.projectID.toLowerCase(),
      subjectKind: params.subjectKind,
      subjectID: params.subjectID.toLowerCase(),
      familyID: familyID.toLowerCase(),
      version,
      supersedesPolicyID: params.supersedesPolicyID?.toLowerCase(),
      namespace,
      sensitivity: params.sensitivity ?? 'project',
      visibility: params.visibility ?? 'project_members',
      allowedActorIDs: actorIDs,
      allowedPrincipalIDs: principalIDs,
      allowedTaskIDs: taskIDs,
      createdByActorID: params.createdByActorID.toLowerCase(),
      createdAt,
    }),
  )

  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    subjectKind: params.subjectKind,
    subjectID: params.subjectID,
    familyID,
    version,
    supersedesPolicyID: params.supersedesPolicyID,
    namespace,
    sensitivity: params.sensitivity ?? 'project',
    visibility: params.visibility ?? 'project_members',
    allowedActorIDs: actorIDs,
    allowedPrincipalIDs: principalIDs,
    allowedTaskIDs: taskIDs,
    createdByActorID: params.createdByActorID,
    createdAt,
    policySHA256,
  }
}

export function validatePolicyImmutableReceipt(policy: ContextAccessPolicyRecord): void {
  const rebuilt = createContextAccessPolicyRecord({
    id: policy.id,
    projectID: policy.projectID,
    subjectKind: policy.subjectKind,
    subjectID: policy.subjectID,
    familyID: policy.familyID,
    version: policy.version,
    supersedesPolicyID: policy.supersedesPolicyID,
    namespace: policy.namespace,
    sensitivity: policy.sensitivity,
    visibility: policy.visibility,
    allowedActorIDs: policy.allowedActorIDs,
    allowedPrincipalIDs: policy.allowedPrincipalIDs,
    allowedTaskIDs: policy.allowedTaskIDs,
    createdByActorID: policy.createdByActorID,
    createdAt: policy.createdAt,
  })
  if (rebuilt.policySHA256 !== policy.policySHA256) {
    throw ContextKernelValidationError.immutableFingerprintMismatch()
  }
}

function sortedUniqueUUIDs(ids: readonly UUID[]): readonly UUID[] {
  return [...new Set(ids.map((id) => id.toLowerCase()))].sort() as UUID[]
}
