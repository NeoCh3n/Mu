import { useEffect, useState } from 'react'

/**
 * Live SSE subscription to GET /api/events. Returns a rolling buffer of
 * envelopes; the UI renders them as a live event log.
 */
export interface SSEEnvelope {
  readonly event: string
  readonly data: unknown
}

export function useSSE(limit = 200): SSEEnvelope[] {
  const [envelopes, setEnvelopes] = useState<SSEEnvelope[]>([])

  useEffect(() => {
    const source = new EventSource('/api/events')
    const onEvent = (event: MessageEvent) => {
      let data: unknown = event.data
      try {
        data = JSON.parse(event.data) as unknown
      } catch {
        // keep raw text
      }
      const envelope: SSEEnvelope = { event: event.type, data }
      setEnvelopes((previous) => [...previous.slice(-(limit - 1)), envelope])
    }
    source.addEventListener('turn', onEvent)
    source.addEventListener('turn_event', onEvent)
    source.addEventListener('turn_ended', onEvent)
    source.addEventListener('turn_error', onEvent)
    return () => source.close()
  }, [limit])

  return envelopes
}

/** Small async data hook: pending/error/data + refresh. */
export function useQuery<T>(loader: () => Promise<T>, deps: readonly unknown[] = []): {
  data: T | undefined
  error: string | undefined
  reload: () => void
} {
  const [data, setData] = useState<T | undefined>(undefined)
  const [error, setError] = useState<string | undefined>(undefined)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let cancelled = false
    loader()
      .then((value) => {
        if (!cancelled) setData(value)
      })
      .catch((reason: unknown) => {
        if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick])

  return { data, error, reload: () => setTick((t) => t + 1) }
}
