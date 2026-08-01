import Fastify, { type FastifyInstance } from 'fastify'
import {
  bootstrapLocalControlPlane,
  createControlPlaneService,
  type ControlPlaneDependencies,
  type ControlPlaneService,
} from '@mu/core'
import { SQLiteStore } from '@mu/core'
import type { Harness } from '@mu/core'
import { SSEEventHub } from './sse/events.ts'
import { registerRoutes } from './routes/index.ts'

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
  readonly harness: Harness
  /** Closes the store and the Fastify instance. */
  readonly close: () => Promise<void>
}

export function buildApp(config: MuAppConfig): MuApp {
  const store = new SQLiteStore({
    dataDirectory: config.dataDirectory,
    filename: config.filename ?? 'mu.sqlite',
  })
  const now = config.now ?? (() => new Date())
  const hub = new SSEEventHub()

  let harness: Harness
  if (config.harness !== undefined) {
    harness = config.harness
  } else {
    // Local mode: discover executables and seed default agents/endpoints.
    const bootstrapped = bootstrapLocalControlPlane({
      dataDirectory: config.dataDirectory,
      filename: config.filename,
      claudeCodeExecutable: config.claudeCodeExecutable,
      codexExecutable: config.codexExecutable,
      principalID: config.principalID,
      now,
    })
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

  registerRoutes(app, { service, hub, now })

  app.get('/health', async () => ({
    ok: true,
    mode: harness.capabilities.mode,
    providerCount: harness.capabilities.providers.length,
    time: now().toISOString(),
  }))

  return {
    app,
    service,
    store,
    hub,
    harness,
    close: async () => {
      await app.close()
      store.close()
    },
  }
}
