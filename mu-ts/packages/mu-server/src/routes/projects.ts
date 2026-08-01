import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { RouteContext } from './index.ts'

interface ProjectBody {
  readonly displayName: string
  readonly repositoryPath?: string
  readonly ownerPrincipalID?: string
}

interface AgentBody {
  readonly displayName: string
  readonly shortName: string
  readonly role: string
  readonly summary: string
  readonly preferredEndpointID?: string
  readonly capabilityTags?: readonly string[]
  readonly accentHex?: string
}

interface EndpointBody {
  readonly runtimeTypeID: string
  readonly displayName: string
  readonly runtimeVersion: string
  readonly location: string
}

interface ProjectUpdateBody {
  readonly displayName?: string
}

export function registerProjectsRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { service } = ctx

  app.get('/projects', async () => ({ projects: service.listProjects() }))

  app.post('/projects', async (request: FastifyRequest<{ Body: ProjectBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.displayName !== 'string' || body.displayName.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'displayName is required.' })
    }
    const project = service.createProject({
      displayName: body.displayName.trim(),
      repositoryPath: body.repositoryPath,
      ownerPrincipalID: (body.ownerPrincipalID ?? 'local-user') as never,
    })
    return { project }
  })

  app.patch('/projects/:id', async (request: FastifyRequest<{ Params: { id: string }; Body: ProjectUpdateBody }>, reply: FastifyReply) => {
    const displayName = request.body?.displayName
    if (typeof displayName !== 'string' || displayName.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'displayName is required.' })
    }
    return { project: service.renameProject(request.params.id as never, displayName) }
  })

  app.delete('/projects/:id', async (request: FastifyRequest<{ Params: { id: string } }>) => {
    return { project: service.removeProject(request.params.id as never) }
  })

  app.get('/agents', async () => ({ agents: service.listAgents() }))

  app.post('/agents', async (request: FastifyRequest<{ Body: AgentBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.displayName !== 'string' || body.displayName.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'displayName is required.' })
    }
    const agent = service.createAgent({
      displayName: body.displayName.trim(),
      shortName: body.shortName ?? body.displayName.trim().toLowerCase(),
      role: (body.role as 'builder') ?? 'builder',
      summary: body.summary ?? '',
      preferredEndpointID: body.preferredEndpointID as never,
      capabilityTags: body.capabilityTags,
      accentHex: body.accentHex,
    })
    return { agent }
  })

  app.get('/endpoints', async () => ({ endpoints: service.listEndpoints() }))

  app.post('/endpoints', async (request: FastifyRequest<{ Body: EndpointBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.runtimeTypeID !== 'string' || body.runtimeTypeID === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'runtimeTypeID is required.' })
    }
    const endpoint = service.registerEndpoint({
      runtimeTypeID: body.runtimeTypeID,
      displayName: body.displayName ?? body.runtimeTypeID,
      runtimeVersion: body.runtimeVersion ?? 'unknown',
      location: (body.location as 'local') ?? 'local',
    })
    return { endpoint }
  })

  app.post('/endpoints/probe', async () => {
    const outcomes = await service.probeEndpoints()
    return { outcomes }
  })
}
