import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { MuError } from '@mu/core'
import type { RouteContext } from './index.ts'

interface TaskBody {
  readonly projectID?: string
  readonly title: string
  readonly objective: string
  readonly repositoryPath: string
  readonly assignedAgentIdentityID?: string
  readonly requestedByActorID?: string
  readonly successCriteria?: readonly string[]
  readonly constraints?: readonly string[]
}

interface TaskQuery {
  readonly projectID?: string
}

export function registerTasksRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.get('/tasks', async (request: FastifyRequest<{ Querystring: TaskQuery }>) => {
    const tasks = service.listTasks()
    return { tasks: request.query.projectID === undefined ? tasks : tasks.filter((task) => task.projectID === request.query.projectID) }
  })

  app.get('/tasks/:id', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    const task = service.fetchTask(request.params.id as never)
    if (task === undefined) {
      return reply.status(404).send({ error: 'not_found', message: `Task ${request.params.id} was not found.` })
    }
    return { task }
  })

  app.post('/tasks', async (request: FastifyRequest<{ Body: TaskBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'title is required.' })
    }
    if (typeof body.objective !== 'string' || body.objective.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'objective is required.' })
    }
    if (typeof body.repositoryPath !== 'string' || body.repositoryPath.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'repositoryPath is required.' })
    }
    const task = service.createTask({
      projectID: (body.projectID ?? '') as never,
      title: body.title.trim(),
      objective: body.objective.trim(),
      repositoryPath: body.repositoryPath,
      assignedAgentIdentityID: body.assignedAgentIdentityID as never,
      requestedByActorID: body.requestedByActorID as never,
      successCriteria: body.successCriteria,
      constraints: body.constraints,
    })
    return { task }
  })

  app.get('/tasks/:id/chat', async (request: FastifyRequest<{ Params: { id: string } }>) => {
    return { entries: service.listChatEntries(request.params.id as never) }
  })

  app.get('/tasks/:id/runs', async (request: FastifyRequest<{ Params: { id: string } }>) => {
    return { runs: service.listRuns(request.params.id as never) }
  })

  app.get('/tasks/:id/artifacts', async (request: FastifyRequest<{ Params: { id: string } }>) => {
    return { artifacts: service.listRuntimeArtifacts(request.params.id as never) }
  })

  app.get('/tasks/:id/handoffs', async (request: FastifyRequest<{ Params: { id: string } }>) => {
    return { handoffs: service.listHandoffs(request.params.id as never) }
  })

  app.get('/tasks/:id/context', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    const task = service.fetchTask(request.params.id as never)
    if (task === undefined || task.projectID === undefined) {
      return reply.status(404).send({ error: 'not_found', message: 'Task or its project was not found.' })
    }
    return { records: service.listContextRecords(task.projectID as never) }
  })

  app.get('/tasks/:id/ledger', async (request: FastifyRequest<{ Params: { id: string } }>) => {
    return { events: service.fetchLedger(request.params.id as never) }
  })

  // Shared error mapping for turn-style routes.
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof MuError) {
      const status = error.kind === 'recordNotFound' ? 404
        : error.kind === 'invalidTransition' ? 409
          : error.kind === 'capabilityMissing' ? 503
            : 500
      return reply.status(status).send({ error: error.kind, message: error.message })
    }
    const message = error instanceof Error ? error.message : String(error)
    return reply.status(500).send({ error: 'internal_error', message })
  })
}
