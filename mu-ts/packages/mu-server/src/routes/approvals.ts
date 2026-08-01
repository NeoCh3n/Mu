import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { RouteContext } from './index.ts'

interface ApproveBody {
  readonly decision: string
  readonly approverActorID?: string
  readonly reason?: string
}

export function registerApprovalRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.post('/approvals/:id/resolve', async (request: FastifyRequest<{ Params: { id: string }; Body: ApproveBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    const decision = body.decision
    if (decision !== 'granted' && decision !== 'denied') {
      return reply.status(400).send({ error: 'bad_request', message: 'decision must be granted or denied.' })
    }
    const approval = service.resolveApproval({
      approvalID: request.params.id as never,
      decision,
      approverActorID: (body.approverActorID ?? 'local-user') as never,
      reason: body.reason,
    })
    return { approval }
  })
}
