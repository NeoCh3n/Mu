import type { UUID } from './identity.ts'
import type { AgentRuntimeInstanceIdentity, ConversationProvider } from './types.ts'

export const ExternalConversationRole = {
  user: 'user',
  assistant: 'assistant',
} as const
export type ExternalConversationRole =
  (typeof ExternalConversationRole)[keyof typeof ExternalConversationRole]

export const ConversationAccessKind = {
  vendorProtocol: 'vendor_protocol',
  localReadOnlyArtifact: 'local_read_only_artifact',
} as const
export type ConversationAccessKind =
  (typeof ConversationAccessKind)[keyof typeof ConversationAccessKind]

export const ConversationResumability = {
  resumable: 'resumable',
  historyOnly: 'history_only',
  unavailable: 'unavailable',
} as const
export type ConversationResumability =
  (typeof ConversationResumability)[keyof typeof ConversationResumability]

export const ConversationRefreshState = {
  current: 'current',
  appendOnly: 'append_only',
  sourceChanged: 'source_changed',
} as const
export type ConversationRefreshState =
  (typeof ConversationRefreshState)[keyof typeof ConversationRefreshState]

export interface ExternalConversationMessage {
  readonly nativeItemID: string
  readonly ordinal: number
  readonly role: ExternalConversationRole
  readonly text: string
  readonly phase?: string
  readonly createdAt?: Date
}

export function createExternalConversationMessage(params: {
  nativeItemID: string
  ordinal: number
  role: ExternalConversationRole
  text: string
  phase?: string
  createdAt?: Date
}): ExternalConversationMessage {
  return {
    nativeItemID: params.nativeItemID,
    ordinal: params.ordinal,
    role: params.role,
    text: params.text,
    phase: params.phase,
    createdAt: params.createdAt,
  }
}

export interface ExternalConversationCandidate {
  readonly provider: ConversationProvider
  readonly providerInstanceKey: string
  readonly nativeSessionID: string
  readonly title: string
  readonly canonicalWorkspacePath: string
  readonly createdAt?: Date
  readonly updatedAt?: Date
  readonly isArchived: boolean
  readonly model?: string
  readonly agentLabel?: string
  readonly accessKind: ConversationAccessKind
  readonly resumability: ConversationResumability
  readonly sourceLocation?: string
  readonly warnings: readonly string[]
  readonly discoveredMessageCount?: number
  readonly messages: readonly ExternalConversationMessage[]
  readonly runtimeInstanceIdentity?: AgentRuntimeInstanceIdentity
}

export function externalCandidateID(candidate: ExternalConversationCandidate): string {
  return [
    candidate.provider.rawValue,
    candidate.providerInstanceKey,
    candidate.nativeSessionID,
    candidate.canonicalWorkspacePath,
  ].join('\u{1F}')
}

export function createExternalConversationCandidate(params: {
  provider: ConversationProvider
  providerInstanceKey: string
  nativeSessionID: string
  title: string
  canonicalWorkspacePath: string
  createdAt?: Date
  updatedAt?: Date
  isArchived?: boolean
  model?: string
  agentLabel?: string
  accessKind: ConversationAccessKind
  resumability: ConversationResumability
  sourceLocation?: string
  warnings?: readonly string[]
  discoveredMessageCount?: number
  messages?: readonly ExternalConversationMessage[]
  runtimeInstanceIdentity?: AgentRuntimeInstanceIdentity
}): ExternalConversationCandidate {
  return {
    provider: params.provider,
    providerInstanceKey: params.providerInstanceKey,
    nativeSessionID: params.nativeSessionID,
    title: params.title,
    canonicalWorkspacePath: params.canonicalWorkspacePath,
    createdAt: params.createdAt,
    updatedAt: params.updatedAt,
    isArchived: params.isArchived ?? false,
    model: params.model,
    agentLabel: params.agentLabel,
    accessKind: params.accessKind,
    resumability: params.resumability,
    sourceLocation: params.sourceLocation,
    warnings: params.warnings ?? [],
    discoveredMessageCount: params.discoveredMessageCount,
    messages: params.messages ?? [],
    runtimeInstanceIdentity: params.runtimeInstanceIdentity,
  }
}

/**
 * Extension contract for adding another Agent's project-scoped conversation
 * history without coupling its native format to Mu's storage, UI, or Context
 * policy. Discovery returns bounded metadata shells; hydration returns only
 * visible user/assistant content.
 */
export interface ConversationHistoryAdapter {
  readonly provider: ConversationProvider
  readonly providerInstanceKey: string

  discoverConversationHistory(
    canonicalWorkspacePath: string,
  ): Promise<ExternalConversationCandidate[]>

  hydrateConversationHistory(
    candidate: ExternalConversationCandidate,
  ): Promise<ExternalConversationCandidate>
}

/** ConversationProvider values for the built-in providers. */
export const CODE_PROVIDER: ConversationProvider = { rawValue: 'codex' }
export const CLAUDE_CODE_PROVIDER: ConversationProvider = { rawValue: 'claude_code' }
export const OPEN_WORKER_PROVIDER: ConversationProvider = { rawValue: 'openworker' }

/** Canonical workspace path resolution with tilde expansion (Swift-style). */
export function canonicalWorkspacePath(rawPath: string): string {
  const expanded = rawPath.replace(/^~(?=\/|$)/, process.env.HOME ?? '~').trim()
  if (!expanded.startsWith('/')) {
    throw new Error('Workspace path must be absolute.')
  }
  return canonicalWorkspacePathUnchecked(expanded)
}

import { canonicalPath } from './paths.ts'

function canonicalWorkspacePathUnchecked(p: string): string {
  return canonicalPath(p)
}
