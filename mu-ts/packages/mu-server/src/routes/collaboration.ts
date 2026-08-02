import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import {
  isUUID,
  stableId,
  uuid,
  type CollaborationPrincipal,
  type CollaborationService,
  type PresenceState,
  type UUID,
} from '@mu/core'
import { MuError } from '@mu/core'
import type { RouteContext } from './index.ts'

interface SpaceParams {
  readonly spaceID: string
}

interface SyncQuery {
  readonly after?: string
  readonly limit?: string
}

interface SpaceBody {
  readonly displayName: string
  readonly description?: string
}

interface EventBody {
  readonly threadID?: string
  readonly eventType: string
  readonly payload?: Readonly<Record<string, unknown>>
  readonly idempotencyKey: string
}

interface PresenceBody {
  readonly displayName?: string
  readonly state?: PresenceState
  readonly ttlSeconds?: number
}

function header(request: FastifyRequest, name: string): string | undefined {
  const value = request.headers[name]
  return Array.isArray(value) ? value[0] : value
}

function principalFor(request: FastifyRequest): CollaborationPrincipal {
  const actorHeader = header(request, 'x-mu-actor-id')
  if (actorHeader !== undefined && !isUUID(actorHeader)) {
    throw MuError.invalidTransition('x-mu-actor-id must be a UUID.')
  }
  const clientInstanceID = (header(request, 'x-mu-client-instance-id') ?? 'local-client').trim()
  const displayName = (header(request, 'x-mu-display-name') ?? 'Local user').trim()
  if (clientInstanceID.length === 0 || clientInstanceID.length > 160) {
    throw MuError.invalidTransition('x-mu-client-instance-id is invalid.')
  }
  if (displayName.length === 0 || displayName.length > 160) {
    throw MuError.invalidTransition('x-mu-display-name is invalid.')
  }
  return {
    actorID: uuid(actorHeader ?? stableId('mu.local-actor', ['local-user'])),
    clientInstanceID,
    displayName,
  }
}

function spaceIDFrom(params: SpaceParams): UUID {
  if (!isUUID(params.spaceID)) throw MuError.recordNotFound(`Collaboration Space ${params.spaceID}`)
  return uuid(params.spaceID)
}

function cursor(value: string | undefined, fallback: number): number {
  if (value === undefined || value.trim() === '') return fallback
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed < 0) throw MuError.invalidTransition('Sync cursor must be a non-negative number.')
  return Math.floor(parsed)
}

function stringPayload(payload: Readonly<Record<string, unknown>> | undefined): Readonly<Record<string, string>> {
  if (payload === undefined) return {}
  const result: Record<string, string> = {}
  for (const [key, value] of Object.entries(payload)) {
    if (typeof value !== 'string') throw MuError.invalidTransition(`Event payload ${key} must be a string.`)
    result[key] = value
  }
  return result
}

export function registerCollaborationRoutes(app: FastifyInstance, ctx: RouteContext): void {
  const { collaboration } = ctx

  app.get('/spaces', async () => ({ spaces: collaboration.listSpaces() }))

  app.post('/spaces', async (request: FastifyRequest<{ Body: SpaceBody }>, reply: FastifyReply) => {
    const body = request.body ?? {}
    if (typeof body.displayName !== 'string' || body.displayName.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'displayName is required.' })
    }
    return {
      space: collaboration.createSpace({
        displayName: body.displayName,
        description: body.description,
        createdByActorID: principalFor(request).actorID,
      }),
    }
  })

  app.get('/spaces/:spaceID/events', async (
    request: FastifyRequest<{ Params: SpaceParams; Querystring: SyncQuery }>,
  ) => {
    const spaceID = spaceIDFrom(request.params)
    const after = cursor(request.query?.after, 0)
    const limit = cursor(request.query?.limit, 100)
    const batch = collaboration.syncSpace(spaceID, after, limit)
    return {
      spaceID,
      afterSequence: batch.afterSequence,
      nextSequence: batch.nextSequence,
      events: batch.events,
      hasMore: batch.hasMore,
    }
  })

  app.get('/spaces/:spaceID/sync', async (
    request: FastifyRequest<{ Params: SpaceParams; Querystring: SyncQuery }>,
  ) => {
    const spaceID = spaceIDFrom(request.params)
    return collaboration.syncSpace(
      spaceID,
      cursor(request.query?.after, 0),
      cursor(request.query?.limit, 100),
    )
  })

  app.post('/spaces/:spaceID/events', async (
    request: FastifyRequest<{ Params: SpaceParams; Body: EventBody }>,
    reply: FastifyReply,
  ) => {
    const body = request.body ?? {}
    if (typeof body.eventType !== 'string' || body.eventType.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'eventType is required.' })
    }
    if (typeof body.idempotencyKey !== 'string' || body.idempotencyKey.trim() === '') {
      return reply.status(400).send({ error: 'bad_request', message: 'idempotencyKey is required.' })
    }
    if (body.threadID !== undefined && !isUUID(body.threadID)) {
      return reply.status(400).send({ error: 'bad_request', message: 'threadID must be a UUID.' })
    }
    const result = collaboration.appendEvent({
      spaceID: spaceIDFrom(request.params),
      threadID: body.threadID === undefined ? undefined : uuid(body.threadID),
      eventType: body.eventType,
      payload: stringPayload(body.payload),
      idempotencyKey: body.idempotencyKey,
      principal: principalFor(request),
    })
    return reply.status(result.deduplicated ? 200 : 201).send(result)
  })

  app.put('/spaces/:spaceID/presence', async (
    request: FastifyRequest<{ Params: SpaceParams; Body: PresenceBody }>,
  ) => {
    const body = request.body ?? {}
    const state = body.state ?? 'online'
    if (!['online', 'idle', 'offline'].includes(state)) {
      throw MuError.invalidTransition('Presence state is invalid.')
    }
    const requestPrincipal = principalFor(request)
    return {
      presence: collaboration.heartbeatPresence({
        spaceID: spaceIDFrom(request.params),
        principal: {
          ...requestPrincipal,
          displayName: body.displayName ?? requestPrincipal.displayName,
        },
        state,
        ttlSeconds: body.ttlSeconds,
      }),
    }
  })

  app.delete('/spaces/:spaceID/presence', async (
    request: FastifyRequest<{ Params: SpaceParams }>,
  ) => {
    const principal = principalFor(request)
    collaboration.removePresence({
      spaceID: spaceIDFrom(request.params),
      actorID: principal.actorID,
      clientInstanceID: principal.clientInstanceID,
    })
    return { removed: true }
  })
}

