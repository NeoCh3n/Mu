import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { RouteContext } from './index.ts'

interface HandoffBody {
  readonly taskID?: string
  readonly sourceEndpointID?: string
  readonly receiverEndpointID?: string
  readonly validationMessage?: string
}

interface ResolveBody {
  readonly accepted: boolean
  readonly validationMessage?: string
  readonly rejectionReason?: string
}

export function registerHandoffRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.post('/handoffs', async (request: FastifyRequest<{ Body: HandoffBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.taskID !== 'string' || body.taskID === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'taskID is required.' })
    }
    if (typeof body.sourceEndpointID !== 'string' || body.sourceEndpointID === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'sourceEndpointID is required.' })
    }
    if (typeof body.receiverEndpointID !== 'string' || body.receiverEndpointID === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'receiverEndpointID is required.' })
    }
    const handoff = service.proposeHandoff({
      taskID: body.taskID as never,
      sourceEndpointID: body.sourceEndpointID as never,
      receiverEndpointID: body.receiverEndpointID as never,
      validationMessage: body.validationMessage ?? '',
    })
    return { handoff }
  })

  app.post('/handoffs/:id/resolve', async (request: FastifyRequest<{ Params: { id: string }; Body: ResolveBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.accepted !== 'boolean') {
      return reply.status(400).send({ error: 'bad_request', message: 'accepted is required.' })
    }
    const handoff = service.resolveHandoff({
      handoffID: request.params.id as never,
      accepted: body.accepted,
      validationMessage: body.validationMessage ?? '',
      rejectionReason: body.rejectionReason,
    })
    return { handoff }
  })
}
