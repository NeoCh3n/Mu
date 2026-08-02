import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { HostHistoryCandidate } from '@mu/core'
import type { RouteContext } from './index.ts'

interface DiscoverQuery {
  readonly workspacePath?: string
}

interface HydrateBody {
  readonly candidate?: HostHistoryCandidate
}

/** Endpoint-scoped history routes. The host process, not the UI, owns the query. */
export function registerHistoryRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.get('/endpoints/:id/history', async (
    request: FastifyRequest<{ Params: { id: string }; Querystring: DiscoverQuery }>,
    reply: FastifyReply,
  ) => {
    const workspacePath = request.query.workspacePath
    if (typeof workspacePath !== 'string' || workspacePath.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'workspacePath is required.' })
    }
    const conversations = await service.discoverHistory(request.params.id as never, workspacePath)
    return { conversations }
  })

  app.post('/endpoints/:id/history/hydrate', async (
    request: FastifyRequest<{ Params: { id: string }; Body: HydrateBody }>,
    reply: FastifyReply,
  ) => {
    const candidate = request.body?.candidate
    if (candidate === undefined || typeof candidate !== 'object') {
      return reply.status(400).send({ error: 'bad_request', message: 'candidate is required.' })
    }
    const conversation = await service.hydrateHistory(request.params.id as never, candidate)
    return { conversation }
  })
}
