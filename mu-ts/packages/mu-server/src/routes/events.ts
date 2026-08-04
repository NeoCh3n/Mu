import type { FastifyInstance, FastifyRequest } from 'fastify'
import { attachSSEStream } from '../sse/events.ts'
import type { RouteContext } from './index.ts'

/**
 * GET /api/events — live SSE stream. Envelopes:
 *   event: turn        — control-plane run/chat events
 *   event: turn_event  — harness turn events streamed from an active run
 *   event: turn_ended  — a background turn finished
 *   event: turn_error  — a background turn failed
 * Comments (`: open`, `: ping`) keep intermediaries from timing out.
 */
export function registerEventsRoutes(app: FastifyInstance, ctx: RouteContext): void {
  app.get('/api/events', async (
    request: FastifyRequest<{ Querystring: { spaceID?: string } }>,
    reply,
  ) => {
    const spaceID = request.query?.spaceID
    attachSSEStream(
      request,
      reply,
      ctx.hub,
      25_000,
      spaceID === undefined
        ? undefined
        : (envelope) => {
            const data = envelope.data
            return typeof data === 'object'
              && data !== null
              && 'spaceID' in data
              && data.spaceID === spaceID
          },
    )
  })
}
