import type { ExternalConversationCandidate } from '../conversation-history.ts'
import type { HarnessCapabilities } from '../harness/types.ts'
import type {
  HarnessArtifactRecord,
  HarnessPendingApproval,
  HarnessProbeResult,
  HarnessTurnEvent,
  HarnessTurnInput,
  HarnessTurnResult,
} from '../harness/types.ts'

// ---------------------------------------------------------------------------
// AgentHostAdapter — the stable host contract.
//
// An AgentHostAdapter is one execution host behind a stable interface:
// probe / submit / events / interrupt / approvals / artifacts / delivery
// receipt. Hosts include the local child-process runtimes (Claude Code CLI,
// Codex App Server), the Experimental QM Bridge, and future hosts. The
// control plane speaks only this contract — a host never reaches into Mu's
// database or permission truth source.
//
// Responsibility boundary (Mu always owns):
//   - Agent identity, Actor, Principal ownership, Delegation, permissions
//   - Task Leases (fencing tokens) and Context Packs (SHA-256 verified)
//   - Delivery receipts: Mu issues the immutable ContextDeliveryReceipt for
//     every turn; a host that acknowledges deliveries sets deliveryReceipt.
//   - Review/Approval workflow: approval requests surface as events; the
//     decision is Mu's. A host with a resolve channel may expose
//     resolveApproval; otherwise approvals are 'report_only'.
// ---------------------------------------------------------------------------

export type { HarnessTurnInput as HostTurnInput }
export type { HarnessTurnEvent as HostTurnEvent }
export type { HarnessTurnResult as HostTurnResult }
export type { HarnessProbeResult as HostProbeResult }
export type { HarnessArtifactRecord as HostArtifactRecord }
export type { HarnessPendingApproval as HostApprovalRequest }
export type { ExternalConversationCandidate as HostHistoryCandidate }

/** How this host participates in approval flows. */
export const HostApprovalSupport = {
  /** Host only reports pending approvals; Mu resolves them internally. */
  reportOnly: 'report_only',
  /** Host can receive approval decisions over its own channel. */
  resolveForward: 'resolve_forward',
  /** Host has no approval surface. */
  none: 'none',
} as const
export type HostApprovalSupport =
  (typeof HostApprovalSupport)[keyof typeof HostApprovalSupport]

export interface HostCapabilities extends HarnessCapabilities {
  readonly approvals: HostApprovalSupport
  /** Host acknowledges delivery receipts (e.g. QM-style delivery targets). */
  readonly deliveryReceipt: boolean
}

export interface HostApprovalResolution {
  readonly sessionID: string
  readonly requestID: string
  readonly decision: 'granted' | 'denied'
}

// ---------------------------------------------------------------------------
// Host error classification. Hosts throw host-specific errors; the control
// plane and server map them onto MuError kinds via classifyHostError.
// ---------------------------------------------------------------------------

export const HostErrorKind = {
  /** Host executable missing or unusable. */
  unavailable: 'unavailable',
  /** Signature/auth rejection, not logged in. */
  authentication: 'authentication',
  /** Network/transport failure (QM bridge, remote hosts). */
  network: 'network',
  /** The host rejected the request or the command failed. */
  refused: 'refused',
  /** Timeout waiting for a host response. */
  timeout: 'timeout',
  /** Invalid input / protocol violation by Mu. */
  protocol: 'protocol',
  /** Anything else. */
  unknown: 'unknown',
} as const
export type HostErrorKind = (typeof HostErrorKind)[keyof typeof HostErrorKind]

export function classifyHostError(error: unknown): HostErrorKind {
  const message = error instanceof Error ? error.message : String(error)
  const lower = message.toLowerCase()
  if (message.includes('is unavailable') || message.includes('not configured') || message.includes('executable is unavailable')) {
    return HostErrorKind.unavailable
  }
  if (lower.includes('unauthorized') || lower.includes('rejected the source signature') || lower.includes('not logged in')) {
    return HostErrorKind.authentication
  }
  if (lower.includes('network') || lower.includes('unreachable') || lower.includes('failed to fetch') || lower.includes('econnrefused')) {
    return HostErrorKind.network
  }
  if (lower.includes('refused') || lower.includes('security quarantine')) {
    return HostErrorKind.refused
  }
  if (lower.includes('timed out') || lower.includes('timeout')) {
    return HostErrorKind.timeout
  }
  if (lower.includes('invalid transition') || lower.includes('requires')) {
    return HostErrorKind.protocol
  }
  return HostErrorKind.unknown
}

export interface AgentHostAdapter {
  /** Stable host identifier, e.g. 'claude-code.cli', 'codex.app-server', 'qm.bridge'. */
  readonly hostID: string
  readonly capabilities: HostCapabilities
  /** Probes host availability, version, and login state. */
  probe(): Promise<HarnessProbeResult>
  /**
   * Submits one bounded turn and streams its events. Consume the generator
   * to completion; terminal events are 'completed' | 'failed' | 'cancelled'.
   */
  submit(input: HarnessTurnInput, signal?: AbortSignal): AsyncIterable<HarnessTurnEvent>
  /** Interrupts an active turn (local: child process; QM: run ID). */
  interrupt(sessionID: string): Promise<void>
  /** Forwards an approval decision to the host when resolveForward is set. */
  resolveApproval?(resolution: HostApprovalResolution): Promise<void>
  listArtifacts(sessionID: string): Promise<HarnessArtifactRecord[]>
  /**
   * Discovers past conversations for a workspace. Host-internal visibility:
   * the same host process that ran the turns must be queried (Codex threads
   * are process-scoped). Optional — hosts without history omit it.
   */
  discoverHistory?(workspacePath: string): Promise<ExternalConversationCandidate[]>
  /** Stops long-lived host processes (codex app-server, SSE streams). */
  stop?(): void
}
