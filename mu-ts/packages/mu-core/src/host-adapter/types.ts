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
  /** Stops long-lived host processes (codex app-server, SSE streams). */
  stop?(): void
}
