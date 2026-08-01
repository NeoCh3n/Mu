import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { RunRecord } from '@mu/core'
import type { RouteContext } from './index.ts'

interface TurnBody {
  readonly text: string
  readonly endpointID?: string
  readonly promptOverride?: string
  readonly sessionID?: string
  readonly resumeSessionID?: string
}

interface InterruptBody {
  readonly runID?: string
}

/**
 * Starts a turn in the background and resolves with the run record as soon
 * as the control plane has created it (the run_created event is published on
 * the hub synchronously during the first generator step).
 */
export function startTurn(
  ctx: RouteContext,
  params: { taskID: string; text: string; endpointID?: string; promptOverride?: string; sessionID?: string; resumeSessionID?: string },
): Promise<RunRecord> {
  const { service, hub } = ctx
  return new Promise<RunRecord>((resolve, reject) => {
    let settled = false
    const unsubscribe = hub.subscribe((envelope) => {
      if (envelope.event !== 'turn') return
      const data = envelope.data as { kind?: string; run?: RunRecord }
      if (data.kind === 'run_created' && data.run !== undefined) {
        settled = true
        unsubscribe()
        resolve(data.run)
      }
    })

    const iterator = service.runTaskTurn({
      taskID: params.taskID as never,
      text: params.text,
      endpointID: params.endpointID as never,
      promptOverride: params.promptOverride,
      sessionID: params.sessionID,
      resumeSessionID: params.resumeSessionID,
    })

    void (async () => {
      try {
        for await (const event of iterator) {
          if (settled) {
            hub.publish('turn_event', { taskID: params.taskID, event })
          }
        }
        hub.publish('turn_ended', { taskID: params.taskID })
      } catch (error) {
        if (!settled) {
          settled = true
          unsubscribe()
          reject(error)
          return
        }
        hub.publish('turn_error', {
          taskID: params.taskID,
          error: error instanceof Error ? error.message : String(error),
        })
      }
    })()
  })
}

export function registerTurnsRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.post('/tasks/:id/turns', async (request: FastifyRequest<{ Params: { id: string }; Body: TurnBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.text !== 'string' || body.text.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'text is required.' })
    }
    const run = await startTurn(ctx, {
      taskID: request.params.id,
      text: body.text.trim(),
      endpointID: body.endpointID,
      promptOverride: body.promptOverride,
      sessionID: body.sessionID,
      resumeSessionID: body.resumeSessionID,
    })
    return { runID: run.id, taskID: run.taskID, state: run.state }
  })

  app.post('/tasks/:id/interrupt', async (request: FastifyRequest<{ Params: { id: string }; Body: InterruptBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.runID !== 'string' || body.runID === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'runID is required.' })
    }
    await service.interruptRun(body.runID as never)
    return { ok: true }
  })
}
