import type { TaskRecord } from '../models.ts'
import { renderedContextPackMarkdown, type ProjectContextPackRecord } from '../project-kernel/index.ts'
import type { QMHarnessTurnInput } from './types.ts'

// ---------------------------------------------------------------------------
// Mu → QM TurnRequest mapping (Phase 8).
//
// Mu's bounded Context Pack becomes QM's system prompt; the user message is
// appended as the turn text. The conversation thread is the Mu task ID, so
// follow-ups on the same task resume the same QM thread. Mu always asserts a
// bot actor with its agent display name.
// ---------------------------------------------------------------------------

export interface MuToQMTurnMapping {
  readonly surface: string
  readonly task: TaskRecord
  readonly contextPack: ProjectContextPackRecord
  readonly text: string
  readonly agentName: string
  readonly actorExternalID: string
  readonly threadRef?: string
  readonly model?: string
  readonly fastMode?: boolean
  readonly readOnly?: boolean
  readonly idempotencyKey?: string
}

export function qmTurnRequestForMu(params: MuToQMTurnMapping): QMHarnessTurnInput {
  const prompt = renderedContextPackMarkdown(params.contextPack)
  return {
    surface: params.surface,
    actor: {
      externalId: params.actorExternalID,
      displayName: params.agentName,
      isBot: true,
    },
    conversation: {
      kind: 'direct',
      threadRef: params.threadRef ?? params.task.id,
      channelName: params.task.title,
      isPrivate: true,
    },
    text: `${prompt}\n\n## Turn request\n\n${params.text}`,
    origin: { kind: 'automation', screenData: `mu:${params.task.id}` },
    model: params.model,
    fastMode: params.fastMode,
    readOnly: params.readOnly ?? true,
    idempotencyKey: params.idempotencyKey,
  }
}
