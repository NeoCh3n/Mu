import type { FastifyInstance, FastifyRequest } from 'fastify'
import type { RouteContext } from './index.ts'

export function registerLedgerRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.get('/ledger', async (request: FastifyRequest<{ Querystring: { taskID?: string; limit?: string } }>) => {
    const { taskID, limit } = request.query
    const parsedLimit = limit === undefined ? undefined : Number(limit)
    const events = service.fetchLedger(
      taskID === undefined || taskID === '' ? undefined : (taskID as never),
      Number.isFinite(parsedLimit) ? parsedLimit : undefined,
    )
    return { events }
  })
}
