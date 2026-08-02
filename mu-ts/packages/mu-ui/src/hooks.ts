import { useCallback, useEffect, useState } from 'react'
import type { UILanguage } from './i18n.ts'

export const COMPLETION_TOAST_DURATIONS = [2, 4, 6, 10, 15] as const

export interface MuUISettings {
  readonly completionNotificationsEnabled: boolean
  readonly completionToastDuration: number
  readonly language: UILanguage
}

const SETTINGS_STORAGE_KEY = 'mu.ui.settings.v1'
const SETTINGS_CHANGED_EVENT = 'mu:settings-changed'
const DEFAULT_SETTINGS: MuUISettings = {
  completionNotificationsEnabled: true,
  completionToastDuration: 4,
  language: 'en',
}

function readMuUISettings(): MuUISettings {
  if (typeof window === 'undefined') return DEFAULT_SETTINGS
  try {
    const raw = window.localStorage.getItem(SETTINGS_STORAGE_KEY)
    if (raw === null) return DEFAULT_SETTINGS
    const parsed = JSON.parse(raw) as Partial<MuUISettings>
    const duration = Number(parsed.completionToastDuration)
    return {
      completionNotificationsEnabled: parsed.completionNotificationsEnabled !== false,
      completionToastDuration: COMPLETION_TOAST_DURATIONS.includes(duration as (typeof COMPLETION_TOAST_DURATIONS)[number]) ? duration : DEFAULT_SETTINGS.completionToastDuration,
      language: parsed.language === 'zh-Hans' ? 'zh-Hans' : 'en',
    }
  } catch {
    return DEFAULT_SETTINGS
  }
}

function persistMuUISettings(settings: MuUISettings): void {
  if (typeof window === 'undefined') return
  window.localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings))
  window.dispatchEvent(new Event(SETTINGS_CHANGED_EVENT))
}

export function useMuUISettings(): {
  settings: MuUISettings
  updateSettings: (patch: Partial<MuUISettings>) => void
} {
  const [settings, setSettings] = useState<MuUISettings>(readMuUISettings)

  useEffect(() => {
    const onChange = () => setSettings(readMuUISettings())
    window.addEventListener(SETTINGS_CHANGED_EVENT, onChange)
    window.addEventListener('storage', onChange)
    return () => {
      window.removeEventListener(SETTINGS_CHANGED_EVENT, onChange)
      window.removeEventListener('storage', onChange)
    }
  }, [])

  const updateSettings = useCallback((patch: Partial<MuUISettings>) => {
    const next = { ...readMuUISettings(), ...patch }
    setSettings(next)
    persistMuUISettings(next)
  }, [])

  return { settings, updateSettings }
}

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

  const reload = useCallback(() => setTick((t) => t + 1), [])
  return { data, error, reload }
}
