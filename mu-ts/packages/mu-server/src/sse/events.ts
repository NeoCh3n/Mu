import type { FastifyReply, FastifyRequest } from 'fastify'

// ---------------------------------------------------------------------------
// SSE event hub: a small broadcast bus backing GET /api/events. Control-plane
// turn events and ledger entries are published here so the UI (Phase 7) can
// render live streams without polling.
// ---------------------------------------------------------------------------

export interface SSEEnvelope {
  readonly event: string
  readonly data: unknown
}

export type SSEListener = (envelope: SSEEnvelope) => void

export class SSEEventHub {
  private readonly listeners = new Set<SSEListener>()

  /** Number of active client connections (exposed for tests). */
  get clientCount(): number {
    return this.listeners.size
  }

  subscribe(listener: SSEListener): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  publish(event: string, data: unknown): void {
    const envelope: SSEEnvelope = { event, data }
    for (const listener of this.listeners) {
      try {
        listener(envelope)
      } catch {
        // A slow/failed listener must not break the broadcast.
      }
    }
  }
}

/** Formats one SSE envelope as wire bytes (event: / data: / blank line). */
export function formatSSE(envelope: SSEEnvelope): string {
  const data = JSON.stringify(envelope.data)
  return `event: ${envelope.event}\ndata: ${data}\n\n`
}

/**
 * Registers a raw SSE stream on a Fastify reply: headers, open preamble,
 * heartbeat, and per-event writes. Returns the unsubscribe function.
 */
export function attachSSEStream(
  request: FastifyRequest,
  reply: FastifyReply,
  hub: SSEEventHub,
  heartbeatMs = 25_000,
): () => void {
  reply.raw.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  })
  reply.raw.write(': open\n\n')

  const unsubscribe = hub.subscribe((envelope) => {
    if (reply.raw.writableEnded) return
    reply.raw.write(formatSSE(envelope))
  })
  const beat = setInterval(() => {
    if (reply.raw.writableEnded) {
      clearInterval(beat)
      return
    }
    reply.raw.write(': ping\n\n')
  }, heartbeatMs)
  beat.unref?.()

  request.raw.on('close', () => {
    clearInterval(beat)
    unsubscribe()
  })
  return unsubscribe
}
