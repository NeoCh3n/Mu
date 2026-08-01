import type { UUID } from '../identity.ts'
import type { ConversationProvider } from '../types.ts'
import type { ContextRecordKind, ContextScope, ContextSensitivity } from './record.ts'
import type { ContextVisibility } from './policy.ts'
import type { ProjectContextValue } from './values.ts'

/** Portable import format for context. Mirrors AgentContextBundle (Swift). */
export interface AgentContextBundle {
  readonly schemaVersion: string
  readonly bundleID?: string
  readonly agentID: string
  readonly ownerPrincipalID?: string
  readonly sourceProjectID?: string
  readonly runtimeProvider?: ConversationProvider
  readonly runtimeSessionID?: string
  readonly exportedAt: Date
  readonly records: readonly AgentContextBundleRecord[]
  readonly artifacts: readonly AgentContextBundleArtifact[]
  readonly accessPolicy?: AgentContextBundleAccessPolicy
  readonly retentionPolicy?: AgentContextBundleRetentionPolicy
}

export function createAgentContextBundle(params: {
  schemaVersion?: string
  bundleID?: string
  agentID: string
  ownerPrincipalID?: string
  sourceProjectID?: string
  runtimeProvider?: ConversationProvider
  runtimeSessionID?: string
  exportedAt?: Date
  records: readonly AgentContextBundleRecord[]
  artifacts?: readonly AgentContextBundleArtifact[]
  accessPolicy?: AgentContextBundleAccessPolicy
  retentionPolicy?: AgentContextBundleRetentionPolicy
}): AgentContextBundle {
  return {
    schemaVersion: params.schemaVersion ?? '1',
    bundleID: params.bundleID,
    agentID: params.agentID,
    ownerPrincipalID: params.ownerPrincipalID,
    sourceProjectID: params.sourceProjectID,
    runtimeProvider: params.runtimeProvider,
    runtimeSessionID: params.runtimeSessionID,
    exportedAt: params.exportedAt ?? new Date(),
    records: params.records,
    artifacts: params.artifacts ?? [],
    accessPolicy: params.accessPolicy,
    retentionPolicy: params.retentionPolicy,
  }
}

export interface AgentContextBundleRecord {
  readonly externalID?: string
  readonly kind: ContextRecordKind
  readonly subject?: string
  readonly value: ProjectContextValue
  readonly confidence?: number
  readonly validFrom?: Date
  readonly validUntil?: Date
  readonly scope?: ContextScope
  readonly sensitivity?: ContextSensitivity
}

export function createAgentContextBundleRecord(params: {
  externalID?: string
  kind: ContextRecordKind
  subject?: string
  value: ProjectContextValue
  confidence?: number
  validFrom?: Date
  validUntil?: Date
  scope?: ContextScope
  sensitivity?: ContextSensitivity
}): AgentContextBundleRecord {
  return {
    externalID: params.externalID,
    kind: params.kind,
    subject: params.subject,
    value: params.value,
    confidence: params.confidence,
    validFrom: params.validFrom,
    validUntil: params.validUntil,
    scope: params.scope,
    sensitivity: params.sensitivity,
  }
}

export interface AgentContextBundleArtifact {
  readonly artifactID?: string
  readonly name: string
  readonly contentType: string
  readonly uri?: string
}

export function createAgentContextBundleArtifact(params: {
  artifactID?: string
  name: string
  contentType: string
  uri?: string
}): AgentContextBundleArtifact {
  return {
    artifactID: params.artifactID,
    name: params.name,
    contentType: params.contentType,
    uri: params.uri,
  }
}

export interface AgentContextBundleAccessPolicy {
  readonly namespace: string
  readonly visibility: ContextVisibility
  readonly sensitivity: ContextSensitivity
  readonly allowedActorIDs: readonly UUID[]
  readonly allowedPrincipalIDs: readonly UUID[]
  readonly allowedTaskIDs: readonly UUID[]
}

export function createAgentContextBundleAccessPolicy(params: {
  namespace?: string
  visibility?: ContextVisibility
  sensitivity?: ContextSensitivity
  allowedActorIDs?: readonly UUID[]
  allowedPrincipalIDs?: readonly UUID[]
  allowedTaskIDs?: readonly UUID[]
}): AgentContextBundleAccessPolicy {
  return {
    namespace: params.namespace ?? 'project/shared',
    visibility: params.visibility ?? 'project_members',
    sensitivity: params.sensitivity ?? 'project',
    allowedActorIDs: params.allowedActorIDs ?? [],
    allowedPrincipalIDs: params.allowedPrincipalIDs ?? [],
    allowedTaskIDs: params.allowedTaskIDs ?? [],
  }
}

export interface AgentContextBundleRetentionPolicy {
  readonly retainUntil?: Date
  readonly deleteRawAfterImport: boolean
}

export function createAgentContextBundleRetentionPolicy(params: {
  retainUntil?: Date
  deleteRawAfterImport?: boolean
}): AgentContextBundleRetentionPolicy {
  return {
    retainUntil: params.retainUntil,
    deleteRawAfterImport: params.deleteRawAfterImport ?? false,
  }
}
