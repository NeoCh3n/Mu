import { useCallback, useEffect, useState } from 'react'

export type CollaborationSpaceStatus = 'active' | 'archived'
export type PresenceState = 'online' | 'idle' | 'offline'

export interface CollaborationSpace {
  readonly id: string
  readonly displayName: string
  readonly description: string
  readonly createdByActorID?: string
  readonly status: CollaborationSpaceStatus
  readonly version: number
  readonly createdAt: string
  readonly updatedAt: string
}

export interface SpaceEventRecord {
  readonly id: string
  readonly spaceID: string
  readonly threadID?: string
  readonly actorID: string
  readonly clientInstanceID: string
  readonly sequence: number
  readonly eventType: string
  readonly payload: Readonly<Record<string, string>>
  readonly idempotencyKey: string
  readonly occurredAt: string
}

export interface PresenceSessionRecord {
  readonly id: string
  readonly spaceID: string
  readonly actorID: string
  readonly clientInstanceID: string
  readonly displayName: string
  readonly state: PresenceState
  readonly lastSeenAt: string
  readonly expiresAt: string
}

export interface SpaceSyncBatch {
  readonly spaceID: string
  readonly afterSequence: number
  readonly nextSequence: number
  readonly events: readonly SpaceEventRecord[]
  readonly presence: readonly PresenceSessionRecord[]
  readonly hasMore: boolean
}

export interface CollaborationIdentity {
  readonly actorID: string
  readonly clientInstanceID: string
  readonly displayName: string
}

const ACTOR_STORAGE_KEY = 'mu.collaboration.actor-id.v1'
const CLIENT_STORAGE_KEY = 'mu.collaboration.client-id.v1'
const DISPLAY_NAME_STORAGE_KEY = 'mu.collaboration.display-name.v1'

function randomID(): string {
  const cryptoObject = typeof globalThis.crypto?.randomUUID === 'function' ? globalThis.crypto : undefined
  if (cryptoObject !== undefined) return cryptoObject.randomUUID()
  // The server validates actor ids as UUIDs. Keep the fallback UUID-shaped
  // even in older WebViews where crypto.randomUUID is unavailable.
  const segment = (length: number) => Math.floor(Math.random() * (16 ** length)).toString(16).padStart(length, '0')
  return `${segment(8)}-${segment(4)}-4${segment(3)}-a${segment(3)}-${segment(12)}`
}

function storedValue(key: string, fallback: string): string {
  if (typeof window === 'undefined') return fallback
  const value = window.localStorage.getItem(key)?.trim()
  if (value !== undefined && value.length > 0) return value
  window.localStorage.setItem(key, fallback)
  return fallback
}

/**
 * A Mu installation has one local actor and a stable client-instance id.
 * They are deliberately separate: two windows can act as the same person
 * while still having independent presence sessions.
 */
export function collaborationIdentity(): CollaborationIdentity {
  return {
    actorID: storedValue(ACTOR_STORAGE_KEY, randomID()),
    clientInstanceID: storedValue(CLIENT_STORAGE_KEY, randomID()),
    displayName: storedValue(DISPLAY_NAME_STORAGE_KEY, 'Local user'),
  }
}

export function setCollaborationDisplayName(displayName: string): void {
  if (typeof window === 'undefined') return
  const normalized = displayName.trim()
  if (normalized.length > 0) window.localStorage.setItem(DISPLAY_NAME_STORAGE_KEY, normalized.slice(0, 160))
}

function collaborationHeaders(): HeadersInit {
  const identity = collaborationIdentity()
  return {
    'content-type': 'application/json',
    'x-mu-actor-id': identity.actorID,
    'x-mu-client-instance-id': identity.clientInstanceID,
    'x-mu-display-name': identity.displayName,
  }
}

async function collaborationRequest<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: {
      ...collaborationHeaders(),
      ...(init?.headers ?? {}),
    },
  })
  const body = (await response.json()) as T & { error?: string; message?: string }
  if (!response.ok || body.error !== undefined) {
    throw new Error(body.message ?? body.error ?? `HTTP ${response.status}`)
  }
  return body
}

export const collaborationApi = {
  listSpaces: () => collaborationRequest<{ spaces: CollaborationSpace[] }>('/spaces'),
  createSpace: (displayName: string, description?: string) => collaborationRequest<{ space: CollaborationSpace }>('/spaces', {
    method: 'POST',
    body: JSON.stringify({ displayName, description }),
  }),
  syncSpace: (spaceID: string, afterSequence = 0, limit = 100) => collaborationRequest<SpaceSyncBatch>(
    `/spaces/${encodeURIComponent(spaceID)}/sync?after=${afterSequence}&limit=${limit}`,
  ),
  appendEvent: (spaceID: string, params: { eventType: string; payload?: Readonly<Record<string, string>>; idempotencyKey: string; threadID?: string }) => collaborationRequest<{ event: SpaceEventRecord; deduplicated: boolean }>(
    `/spaces/${encodeURIComponent(spaceID)}/events`,
    { method: 'POST', body: JSON.stringify(params) },
  ),
  heartbeatPresence: (spaceID: string, params: { displayName?: string; state?: PresenceState; ttlSeconds?: number } = {}) => collaborationRequest<{ presence: PresenceSessionRecord }>(
    `/spaces/${encodeURIComponent(spaceID)}/presence`,
    { method: 'PUT', body: JSON.stringify(params) },
  ),
  removePresence: (spaceID: string) => collaborationRequest<{ removed: boolean }>(
    `/spaces/${encodeURIComponent(spaceID)}/presence`,
    { method: 'DELETE' },
  ),
}

export interface SpaceSyncState {
  readonly batch: SpaceSyncBatch | undefined
  readonly error: string | undefined
  readonly syncing: boolean
  readonly connected: boolean
}

/**
 * Initial snapshot + SSE invalidation + heartbeat. The ordered event cursor
 * remains authoritative, so reconnects and missed SSE frames are safe.
 */
export function useCollaborationSpace(spaceID: string | undefined): SpaceSyncState & { refresh: () => void } {
  const [state, setState] = useState<SpaceSyncState>({ batch: undefined, error: undefined, syncing: false, connected: false })
  const [refreshTick, setRefreshTick] = useState(0)

  const refresh = useCallback(() => setRefreshTick((current) => current + 1), [])

  useEffect(() => {
    if (spaceID === undefined) {
      setState({ batch: undefined, error: undefined, syncing: false, connected: false })
      return
    }
    let cancelled = false
    const load = async (): Promise<void> => {
      if (!cancelled) setState((current) => ({ ...current, syncing: true, error: undefined }))
      try {
        const result = await collaborationApi.syncSpace(spaceID, 0)
        if (cancelled) return
        setState({ batch: result, error: undefined, syncing: false, connected: true })
      } catch (reason) {
        if (cancelled) return
        setState((current) => ({ ...current, error: reason instanceof Error ? reason.message : String(reason), syncing: false, connected: false }))
      }
    }
    void load()

    const source = new EventSource(`/api/events?spaceID=${encodeURIComponent(spaceID)}`)
    const onEvent = () => {
      // Fetch the ordered cursor rather than trusting an SSE frame as state.
      void load()
    }
    source.addEventListener('space_event', onEvent)
    source.addEventListener('presence', onEvent)
    source.onopen = () => setState((current) => ({ ...current, connected: true }))
    source.onerror = () => setState((current) => ({ ...current, connected: false }))

    const heartbeat = window.setInterval(() => {
      void collaborationApi.heartbeatPresence(spaceID).then(() => {
        if (!cancelled) setState((current) => ({ ...current, connected: true }))
      }).catch(() => {
        if (!cancelled) setState((current) => ({ ...current, connected: false }))
      })
    }, 20_000)
    void collaborationApi.heartbeatPresence(spaceID).catch(() => undefined)

    return () => {
      cancelled = true
      source.close()
      window.clearInterval(heartbeat)
      void collaborationApi.removePresence(spaceID).catch(() => undefined)
    }
  }, [refreshTick, spaceID])

  return { ...state, refresh }
}
