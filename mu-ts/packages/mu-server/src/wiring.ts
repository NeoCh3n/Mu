import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify'
import {
  bootstrapLocalControlPlane,
  CollaborationService,
  createControlPlaneService,
  type ControlPlaneDependencies,
  type ControlPlaneService,
} from '@mu/core'
import { SQLiteStore } from '@mu/core'
import type { Harness } from '@mu/core'
import { SSEEventHub } from './sse/events.ts'
import { registerRoutes } from './routes/index.ts'

// ---------------------------------------------------------------------------
// Built UI hosting: the server doubles as the app. The SPA build lives in
// packages/mu-ui/dist; missing builds are reported on / instead of 404ing.
// ---------------------------------------------------------------------------

const UI_DIST = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../mu-ui/dist',
)

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.map': 'application/json',
}

function serveStaticUI(app: FastifyInstance): void {
  const indexHtml = path.join(UI_DIST, 'index.html')
  if (!fs.existsSync(indexHtml)) {
    app.get('/', async () => ({
      error: 'ui_not_built',
      message: 'The Mu UI has not been built yet. Run: pnpm --filter @mu/ui build',
    }))
    return
  }
  const indexSource = fs.readFileSync(indexHtml)

  // Hashed build assets (immutable, safe to cache).
  app.get('/assets/*', (request: FastifyRequest, reply: FastifyReply) => {
    const relative = String((request.params as Record<string, string>)['*'] ?? '')
    const normalized = path.normalize(relative)
    if (normalized.startsWith('..') || normalized.includes('\0') || path.isAbsolute(normalized)) {
      return reply.status(400).send({ error: 'bad_request', message: 'invalid asset path' })
    }
    const file = path.join(UI_DIST, 'assets', normalized)
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
      return reply.status(404).send({ error: 'not_found', message: `asset ${relative} was not found` })
    }
    const extension = path.extname(file).toLowerCase()
    reply.header('cache-control', 'public, max-age=31536000, immutable')
    return reply.type(MIME[extension] ?? 'application/octet-stream').send(fs.readFileSync(file))
  })

  // SPA fallback: every other GET (including /) serves the app shell;
  // API misses stay 404 so the client sees real errors.
  app.setNotFoundHandler((request: FastifyRequest, reply: FastifyReply) => {
    const url = request.url.split('?')[0] ?? '/'
    const isApi = url.startsWith('/api') || url.startsWith('/health')
    if (request.method !== 'GET' || isApi) {
      return reply.status(404).send({ message: `Route ${request.method} ${request.url} not found`, error: 'Not Found', statusCode: 404 })
    }
    return reply.type('text/html; charset=utf-8').send(indexSource)
  })
}

// ---------------------------------------------------------------------------
// buildApp(config): manual DI, mirroring the QM wiring pattern. Everything
// the routes need is constructed here and handed to registerRoutes.
// ---------------------------------------------------------------------------

export interface MuAppConfig {
  /** Directory that will contain mu.sqlite and the cas/ tree. */
  readonly dataDirectory: string
  /** ':memory:' for tests. */
  readonly filename?: string
  readonly claudeCodeExecutable?: string
  readonly codexExecutable?: string
  /** Inject a harness (tests use a mock). */
  readonly harness?: Harness
  readonly principalID?: string
  readonly now?: () => Date
  readonly logger?: boolean
}

export interface MuApp {
  readonly app: FastifyInstance
  readonly service: ControlPlaneService
  readonly store: SQLiteStore
  readonly hub: SSEEventHub
  readonly collaboration: CollaborationService
  readonly harness: Harness
  /** Closes the store and the Fastify instance. */
  readonly close: () => Promise<void>
}

export function buildApp(config: MuAppConfig): MuApp {
  const now = config.now ?? (() => new Date())
  const hub = new SSEEventHub()

  let store: SQLiteStore
  let harness: Harness
  if (config.harness !== undefined) {
    store = new SQLiteStore({
      dataDirectory: config.dataDirectory,
      filename: config.filename ?? 'mu.sqlite',
    })
    harness = config.harness
  } else {
    // Local mode: bootstrap owns the single SQLite connection and seeds the
    // same store that the server service will use. It discovers runtimes but
    // leaves Agent identities optional. Opening a second store here would
    // leave a live connection behind and weaken the single-writer rule.
    const bootstrapped = bootstrapLocalControlPlane({
      dataDirectory: config.dataDirectory,
      filename: config.filename,
      claudeCodeExecutable: config.claudeCodeExecutable,
      codexExecutable: config.codexExecutable,
      principalID: config.principalID,
      now,
    })
    store = bootstrapped.store
    harness = bootstrapped.harness
  }

  // One service instance observes the hub; bootstrapped seeds live in the store.
  const deps: ControlPlaneDependencies = {
    store,
    harness,
    now,
    onEvent: (event) => hub.publish('turn', event),
  }
  const service = createControlPlaneService(deps)
  const collaboration = new CollaborationService(store, {
    now,
    onEnvelope: (envelope) => hub.publish(envelope.event, envelope.data),
  })

  // Warm long-lived local hosts in the background so a new Project does not
  // pay for app-server process creation and protocol initialization.
  void service.warmEndpoints()

  // Every deployment has at least one routable endpoint: injected harnesses
  // (tests, QM) get a managed default; the bootstrapped path keeps its own.
  if (service.listEndpoints().length === 0) {
    service.registerEndpoint({
      runtimeTypeID: 'anthropic.claude-code/cli',
      displayName: 'Claude Code (managed)',
      runtimeVersion: 'managed',
      location: 'local',
    })
  }

  const app = Fastify({ logger: config.logger ?? false })

  registerRoutes(app, { service, hub, now, collaboration })

  app.get('/health', async () => ({
    ok: true,
    mode: harness.capabilities.mode,
    providerCount: harness.capabilities.providers.length,
    time: now().toISOString(),
  }))

  // The server doubles as the app: serve the built UI from /.
  serveStaticUI(app)

  return {
    app,
    service,
    store,
    hub,
    collaboration,
    harness,
    close: async () => {
      await app.close()
      service.close()
    },
  }
}
