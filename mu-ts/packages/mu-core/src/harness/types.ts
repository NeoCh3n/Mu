import type { TaskRecord } from '../models.ts'
import type { ProjectContextPackRecord } from '../project-kernel/index.ts'
import type { ExternalConversationCandidate } from '../conversation-history.ts'
import type { ConversationProvider } from '../types.ts'
import type { RuntimeControlMode, RuntimeObservationFidelity } from '../runtime-gateway/manifest.ts'

// ---------------------------------------------------------------------------
// Harness: the dual-mode abstraction. ControlPlaneService never cares whether
// an Agent executes in a local child process or through QM — it speaks to a
// Harness instance. Local mode wraps the Phase 3 runtime clients; QM mode is
// an HMAC-signed HTTP + SSE client against a QM server.
// ---------------------------------------------------------------------------

export const HarnessMode = {
  local: 'local',
  qm: 'qm',
} as const
export type HarnessMode = (typeof HarnessMode)[keyof typeof HarnessMode]

export interface HarnessCapabilities {
  readonly mode: HarnessMode
  readonly providers: readonly ConversationProvider[]
  /** Gateway control mode this harness can fulfill (see RuntimeControlMode). */
  readonly controlMode: RuntimeControlMode
  readonly observationFidelity: RuntimeObservationFidelity
  readonly supportsInterrupt: boolean
  readonly supportsArtifacts: boolean
  readonly supportsEventStream: boolean
  readonly notes: readonly string[]
}

export interface HarnessProbeResult {
  readonly ok: boolean
  readonly mode: HarnessMode
  readonly runtimeVersion?: string
  readonly loggedIn?: boolean
  readonly message: string
  readonly latencyMilliseconds: number
}

/**
 * Provider-neutral artifact description. Mu-owned record fields (taskID,
 * bindingID, endpointID) belong to the control plane, which maps these into
 * RuntimeArtifactRecord during Phase 5.
 */
export interface HarnessArtifactRecord {
  readonly name: string
  readonly relativePath: string
  readonly kind: string
  readonly byteCount?: number
  readonly modifiedAt?: Date
  readonly nativeRef?: string
}

export interface HarnessPendingApproval {
  readonly requestID: string
  readonly command: string
  readonly reason: string
  readonly purpose?: string
  readonly summary?: string
  readonly blocksInput?: boolean
}

export type HarnessTurnStatus = 'success' | 'failed' | 'cancelled' | 'pending_approval' | 'queued'

export interface HarnessTurnResult {
  readonly status: HarnessTurnStatus
  /** Native session identifier (Claude session UUID, Codex thread ID, QM run ID). */
  readonly sessionID: string
  readonly output: string
  readonly model?: string
  readonly costUSD?: number
  readonly durationMilliseconds?: number
  readonly errorMessage?: string
  readonly pendingApprovals?: readonly HarnessPendingApproval[]
  readonly runID?: string
}

export type HarnessTurnEvent =
  | { readonly kind: 'session_started'; readonly sessionID: string }
  | { readonly kind: 'visible_text'; readonly text: string }
  | { readonly kind: 'pending_approval'; readonly approvals: readonly HarnessPendingApproval[] }
  | { readonly kind: 'completed'; readonly result: HarnessTurnResult }
  /** Harness-level failure with no result (unavailable executable, network, auth). */
  | { readonly kind: 'failed'; readonly errorMessage: string }
  /** Aborted before a result was produced. */
  | { readonly kind: 'cancelled' }

export function isTerminalHarnessEvent(event: HarnessTurnEvent): boolean {
  return event.kind === 'completed' || event.kind === 'failed' || event.kind === 'cancelled'
}

// ---------------------------------------------------------------------------
// Turn input
// ---------------------------------------------------------------------------

/** QM-mode turn fields (Phase 8 refines the full ContextPack → TurnRequest map). */
export interface QMHarnessTurnInput {
  readonly surface: string
  readonly actor: {
    readonly externalId: string
    readonly displayName?: string
    readonly isBot?: boolean
  }
  readonly conversation: {
    readonly kind: string
    readonly threadRef: string
    readonly channelRef?: string
    readonly channelName?: string
    readonly isPrivate?: boolean
  }
  readonly text: string
  readonly origin?: { readonly kind: 'automation'; readonly screenData?: string }
  readonly model?: string
  readonly readOnly?: boolean
  readonly fastMode?: boolean
  readonly async?: boolean
  readonly idempotencyKey?: string
}

export interface HarnessTurnInput {
  /** Required in local mode; ignored in QM mode (provider is the QM server). */
  readonly provider?: ConversationProvider
  readonly sessionID?: string
  readonly resumeSessionID?: string
  readonly promptOverride?: string
  /** User message text (QM mode derives its turn request from this). */
  readonly text?: string
  /** Local-mode context: task + bounded Context Pack used to build the prompt. */
  readonly task?: TaskRecord
  readonly contextPack?: ProjectContextPackRecord
  /** QM-mode fields; when absent, QM mode derives them from task/contextPack/text. */
  readonly qm?: QMHarnessTurnInput
}

// ---------------------------------------------------------------------------
// Harness protocol
// ---------------------------------------------------------------------------

export interface Harness {
  readonly capabilities: HarnessCapabilities
  /**
   * Runs one turn, streaming events. Consume the generator to completion;
   * terminal events are 'completed' | 'failed' | 'cancelled'.
   */
  runTurn(input: HarnessTurnInput, signal?: AbortSignal): AsyncIterable<HarnessTurnEvent>
  /** Interrupts an active turn. Local mode: active child process. QM mode: run ID. */
  interrupt(sessionID: string): Promise<void>
  probe(): Promise<HarnessProbeResult>
  listArtifacts(sessionID: string): Promise<HarnessArtifactRecord[]>
  /**
   * Discovers past conversations for a workspace (host-internal visibility:
   * Codex threads are only visible to the app-server process that created
   * them). Optional — hosts without history support omit it.
   */
  discoverHistory?(workspacePath: string): Promise<ExternalConversationCandidate[]>
}
