import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { RouteContext } from './index.ts'

interface ImportBody {
  readonly projectID?: string
  readonly taskID?: string
  readonly kind: string
  readonly subject: string
  readonly text: string
  readonly sourceActorID?: string
  readonly externalRef?: string
  readonly confidence?: number
}

interface ReviewBody {
  readonly decision: string
  readonly actorID?: string
}

interface ConflictBody {
  readonly acceptedRecordIDs?: readonly string[]
  readonly actorID?: string
  readonly note?: string
}

export function registerContextRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.post('/context/import', async (request: FastifyRequest<{ Body: ImportBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.kind !== 'string' || body.kind === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'kind is required.' })
    }
    if (typeof body.subject !== 'string' || body.subject === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'subject is required.' })
    }
    if (typeof body.text !== 'string' || body.text === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'text is required.' })
    }
    if (typeof body.projectID !== 'string' || body.projectID === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'projectID is required.' })
    }
    const record = service.importContextRecord({
      projectID: body.projectID as never,
      taskID: body.taskID as never,
      kind: body.kind as never,
      subject: body.subject,
      text: body.text,
      sourceActorID: (body.sourceActorID ?? body.projectID) as never,
      externalRef: body.externalRef,
      confidence: body.confidence,
    })
    return { record }
  })

  app.post('/context/:id/review', async (request: FastifyRequest<{ Params: { id: string }; Body: ReviewBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    const decision = body.decision
    if (decision !== 'accepted' && decision !== 'rejected' && decision !== 'disputed') {
      return reply.status(400).send({ error: 'bad_request', message: 'decision must be accepted, rejected, or disputed.' })
    }
    const record = service.reviewContextRecord({
      recordID: request.params.id as never,
      decision,
      actorID: (body.actorID ?? 'local-user') as never,
    })
    return { record }
  })

  app.post('/context/conflicts/:id/resolve', async (request: FastifyRequest<{ Params: { id: string }; Body: ConflictBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (!Array.isArray(body.acceptedRecordIDs)) {
      return reply.status(400).send({ error: 'bad_request', message: 'acceptedRecordIDs is required.' })
    }
    const conflict = service.resolveConflict({
      conflictID: request.params.id as never,
      acceptedRecordIDs: body.acceptedRecordIDs as never,
      actorID: (body.actorID ?? 'local-user') as never,
      note: body.note,
    })
    return { conflict }
  })
}
