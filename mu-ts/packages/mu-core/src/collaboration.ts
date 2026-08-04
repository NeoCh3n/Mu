import { MuError } from './errors.ts'
import { uuid, type UUID } from './identity.ts'
import type { SQLiteStore } from './persistence/store.ts'

export type CollaborationSpaceStatus = 'active' | 'archived'
export type PresenceState = 'online' | 'idle' | 'offline'

export interface CollaborationSpace {
  readonly id: UUID
  readonly displayName: string
  readonly description: string
  readonly createdByActorID?: UUID
  readonly status: CollaborationSpaceStatus
  readonly version: number
  readonly createdAt: Date
  readonly updatedAt: Date
}

/** Durable shared state. Runtime token/activity deltas do not belong here. */
export interface SpaceEventRecord {
  readonly id: UUID
  readonly spaceID: UUID
  readonly threadID?: UUID
  readonly actorID: UUID
  readonly clientInstanceID: string
  readonly sequence: number
  readonly eventType: string
  readonly payload: Readonly<Record<string, string>>
  readonly idempotencyKey: string
  readonly occurredAt: Date
}

/** Ephemeral client presence; it is never replayed as durable Space history. */
export interface PresenceSessionRecord {
  readonly id: UUID
  readonly spaceID: UUID
  readonly actorID: UUID
  readonly clientInstanceID: string
  readonly displayName: string
  readonly state: PresenceState
  readonly lastSeenAt: Date
  readonly expiresAt: Date
}

export interface CollaborationPrincipal {
  readonly actorID: UUID
  readonly clientInstanceID: string
  readonly displayName: string
}

export interface SpaceSyncBatch {
  readonly spaceID: UUID
  readonly afterSequence: number
  readonly nextSequence: number
  readonly events: readonly SpaceEventRecord[]
  readonly presence: readonly PresenceSessionRecord[]
  readonly hasMore: boolean
}

export type CollaborationEnvelope =
  | { readonly event: 'space_event'; readonly data: SpaceEventRecord }
  | { readonly event: 'presence'; readonly data: PresenceSessionRecord }

export interface AppendSpaceEventInput {
  readonly spaceID: UUID
  readonly threadID?: UUID
  readonly eventType: string
  readonly payload: Readonly<Record<string, string>>
  readonly idempotencyKey: string
  readonly principal: CollaborationPrincipal
}

export interface AppendSpaceEventResult {
  readonly event: SpaceEventRecord
  readonly deduplicated: boolean
}

export interface CollaborationServiceOptions {
  readonly now?: () => Date
  readonly onEnvelope?: (envelope: CollaborationEnvelope) => void
}

export function createCollaborationSpace(params: {
  id?: UUID
  displayName: string
  description?: string
  createdByActorID?: UUID
  status?: CollaborationSpaceStatus
  version?: number
  createdAt?: Date
  updatedAt?: Date
}): CollaborationSpace {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    displayName: params.displayName,
    description: params.description ?? '',
    createdByActorID: params.createdByActorID,
    status: params.status ?? 'active',
    version: params.version ?? 1,
    createdAt: now,
    updatedAt: params.updatedAt ?? now,
  }
}

function boundedText(value: string, name: string, maxLength: number): string {
  const normalized = value.trim()
  if (normalized.length === 0) throw MuError.invalidTransition(`${name} cannot be empty.`)
  if (normalized.length > maxLength) throw MuError.invalidTransition(`${name} exceeds ${maxLength} characters.`)
  return normalized
}

function boundedPayload(payload: Readonly<Record<string, string>>): Readonly<Record<string, string>> {
  const entries = Object.entries(payload)
  if (entries.length > 32) throw MuError.invalidTransition('A Space event may contain at most 32 payload fields.')
  const result: Record<string, string> = {}
  for (const [key, value] of entries) {
    const normalizedKey = boundedText(key, 'Event payload key', 80)
    if (typeof value !== 'string' || value.length > 8_000) {
      throw MuError.invalidTransition(`Event payload value for ${normalizedKey} is invalid.`)
    }
    result[normalizedKey] = value
  }
  return result
}

/**
 * Shared local transport boundary. It is store-backed, so multiple Mu clients
 * connected to the same local server observe one ordered Space stream. A
 * remote transport can replace this class without changing the UI contract.
 */
export class CollaborationService {
  private readonly store: SQLiteStore
  private readonly now: () => Date
  private readonly onEnvelope?: (envelope: CollaborationEnvelope) => void

  constructor(
    store: SQLiteStore,
    options: CollaborationServiceOptions = {},
  ) {
    this.store = store
    this.now = options.now ?? (() => new Date())
    this.onEnvelope = options.onEnvelope
  }

  createSpace(params: {
    id?: UUID
    displayName: string
    description?: string
    createdByActorID?: UUID
  }): CollaborationSpace {
    const space = createCollaborationSpace({
      id: params.id,
      displayName: boundedText(params.displayName, 'Space name', 160),
      description: params.description?.trim().slice(0, 2_000),
      createdByActorID: params.createdByActorID,
      createdAt: this.now(),
    })
    this.store.upsertRecord({
      kind: 'collaboration_space',
      id: space.id,
      sortAt: space.updatedAt,
      value: space,
    })
    return space
  }

  /** Creates the deterministic Project-backed room when it does not exist. */
  ensureSpace(params: {
    id: UUID
    displayName: string
    description?: string
    createdByActorID?: UUID
  }): CollaborationSpace {
    return this.fetchSpace(params.id) ?? this.createSpace(params)
  }

  listSpaces(): CollaborationSpace[] {
    return this.store.fetchRecords<CollaborationSpace>('collaboration_space')
  }

  fetchSpace(spaceID: UUID): CollaborationSpace | undefined {
    return this.store.fetchRecord<CollaborationSpace>('collaboration_space', spaceID)
  }

  renameSpace(spaceID: UUID, displayName: string): CollaborationSpace {
    const current = this.fetchSpace(spaceID)
    if (current === undefined) throw MuError.recordNotFound(`Collaboration Space ${spaceID}`)
    const renamed: CollaborationSpace = {
      ...current,
      displayName: boundedText(displayName, 'Space name', 160),
      version: current.version + 1,
      updatedAt: this.now(),
    }
    this.store.upsertRecord({ kind: 'collaboration_space', id: renamed.id, sortAt: renamed.updatedAt, value: renamed })
    return renamed
  }

  archiveSpace(spaceID: UUID): CollaborationSpace {
    const current = this.fetchSpace(spaceID)
    if (current === undefined) throw MuError.recordNotFound(`Collaboration Space ${spaceID}`)
    const archived: CollaborationSpace = { ...current, status: 'archived', version: current.version + 1, updatedAt: this.now() }
    this.store.upsertRecord({ kind: 'collaboration_space', id: archived.id, sortAt: archived.updatedAt, value: archived })
    return archived
  }

  appendEvent(input: AppendSpaceEventInput): AppendSpaceEventResult {
    const eventType = boundedText(input.eventType, 'Event type', 120)
    const idempotencyKey = boundedText(input.idempotencyKey, 'Idempotency key', 200)
    const clientInstanceID = boundedText(input.principal.clientInstanceID, 'Client instance ID', 160)
    const existing = this.store.fetchSpaceEventByIdempotency(input.spaceID, idempotencyKey)
    if (existing !== undefined) {
      if (
        existing.eventType !== eventType
        || JSON.stringify(existing.payload) !== JSON.stringify(boundedPayload(input.payload))
        || existing.threadID !== input.threadID
      ) {
        throw MuError.invalidTransition(`Idempotency key ${idempotencyKey} was already used for a different event.`)
      }
      return { event: existing, deduplicated: true }
    }

    const space = this.fetchSpace(input.spaceID)
    if (space === undefined) throw MuError.recordNotFound(`Collaboration Space ${input.spaceID}`)
    if (space.status !== 'active') throw MuError.invalidTransition(`Collaboration Space ${input.spaceID} is archived.`)

    const payload = boundedPayload(input.payload)
    const event = this.store.withTransaction(() => {
      const sequence = this.store.nextSpaceEventSequence(input.spaceID)
      const value: SpaceEventRecord = {
        id: uuid(),
        spaceID: input.spaceID,
        threadID: input.threadID,
        actorID: input.principal.actorID,
        clientInstanceID,
        sequence,
        eventType,
        payload,
        idempotencyKey,
        occurredAt: this.now(),
      }
      this.store.insertSpaceEvent(value)
      return value
    })
    this.onEnvelope?.({ event: 'space_event', data: event })
    return { event, deduplicated: false }
  }

  syncSpace(spaceID: UUID, afterSequence = 0, limit = 100): SpaceSyncBatch {
    if (this.fetchSpace(spaceID) === undefined) throw MuError.recordNotFound(`Collaboration Space ${spaceID}`)
    const safeAfter = Number.isFinite(afterSequence) && afterSequence >= 0
      ? Math.floor(afterSequence)
      : 0
    const safeLimit = Number.isFinite(limit)
      ? Math.min(500, Math.max(1, Math.floor(limit)))
      : 100
    const events = this.store.fetchSpaceEvents(spaceID, safeAfter, safeLimit)
    const nextSequence = this.store.latestSpaceEventSequence(spaceID)
    return {
      spaceID,
      afterSequence: safeAfter,
      nextSequence,
      events,
      presence: this.store.fetchPresenceSessions(spaceID, this.now()),
      hasMore: events.length === safeLimit && events.at(-1)?.sequence !== nextSequence,
    }
  }

  heartbeatPresence(params: {
    spaceID: UUID
    principal: CollaborationPrincipal
    state?: PresenceState
    ttlSeconds?: number
  }): PresenceSessionRecord {
    if (this.fetchSpace(params.spaceID) === undefined) throw MuError.recordNotFound(`Collaboration Space ${params.spaceID}`)
    const now = this.now()
    const ttl = Math.min(300, Math.max(10, Math.floor(params.ttlSeconds ?? 45)))
    const existing = this.store.fetchPresenceSession(
      params.spaceID,
      params.principal.actorID,
      params.principal.clientInstanceID,
    )
    const presence: PresenceSessionRecord = {
      id: existing?.id ?? uuid(),
      spaceID: params.spaceID,
      actorID: params.principal.actorID,
      clientInstanceID: boundedText(params.principal.clientInstanceID, 'Client instance ID', 160),
      displayName: boundedText(params.principal.displayName, 'Display name', 160),
      state: params.state ?? 'online',
      lastSeenAt: now,
      expiresAt: new Date(now.getTime() + ttl * 1_000),
    }
    this.store.upsertPresenceSession(presence)
    this.onEnvelope?.({ event: 'presence', data: presence })
    return presence
  }

  removePresence(params: {
    spaceID: UUID
    actorID: UUID
    clientInstanceID: string
  }): void {
    this.store.deletePresenceSession(params.spaceID, params.actorID, params.clientInstanceID)
  }
}
