import { MuError } from '../errors.ts'
import { createHarness, type Harness } from '../harness/index.ts'
import { claudeCodeExecutableURL } from '../runtime-clients/claude-code.ts'
import { codexExecutableURL } from '../runtime-clients/codex.ts'
import { SQLiteStore } from '../persistence/store.ts'
import {
  createControlPlaneService,
  type ControlPlaneService,
} from './service.ts'
import { probeEndpoints } from './probes.ts'

export interface BootstrapLocalControlPlaneOptions {
  readonly dataDirectory: string
  /** ':memory:' for tests. */
  readonly filename?: string
  readonly claudeCodeExecutable?: string
  readonly codexExecutable?: string
  readonly principalID?: string
  readonly now?: () => Date
}

export interface BootstrappedControlPlane {
  readonly service: ControlPlaneService
  readonly store: SQLiteStore
  readonly harness: Harness
  /** IDs of optional identities created by an embedding, if any. */
  readonly agentIDs: Record<string, string>
  /** IDs of the endpoints created from discovered executables. */
  readonly endpointIDs: Record<string, string>
}

/**
 * Assembles a local-mode deployment: SQLite store, a local harness built
 * from discovered executables (or injected paths) and registered endpoints.
 * Agent identities are deliberately not seeded: a Task can run directly
 * through a local Runtime and acquire a reusable identity later.
 */
export function bootstrapLocalControlPlane(
  options: BootstrapLocalControlPlaneOptions,
): BootstrappedControlPlane {
  const store = new SQLiteStore({
    dataDirectory: options.dataDirectory,
    filename: options.filename,
  })
  const now = options.now ?? (() => new Date())

  // Resolve executables once and feed the same paths to the harness and to
  // endpoint registration, so the harness can actually drive its endpoints.
  const claudeExe = options.claudeCodeExecutable ?? claudeCodeExecutableURL()
  const codexExe = options.codexExecutable ?? codexExecutableURL()

  const harness = createHarness({
    mode: 'local',
    local: {
      ...(claudeExe !== undefined ? { claudeCodeExecutable: claudeExe } : {}),
      ...(codexExe !== undefined ? { codexExecutable: codexExe } : {}),
    },
  })

  const service = createControlPlaneService({ store, harness, now })

  const principalID = options.principalID ?? 'local-user'

  // Endpoints from discovered executables, each carrying its real instance
  // identity (executable path, surface kind, stable key) so the UI can show
  // Codex Desktop vs Codex CLI vs a specific Claude Code terminal.
  const endpointIDs: Record<string, string> = {}
  if (claudeExe !== undefined) {
    const endpoint = service.registerEndpoint({
      runtimeTypeID: 'anthropic.claude-code/cli',
      displayName: 'Claude Code (local)',
      runtimeVersion: 'local',
      location: 'local',
      instanceIdentity: {
        provider: { rawValue: 'claude_code' },
        surfaceKind: 'terminal_cli',
        identityBasis: 'installation',
        stableInstanceKey: `claude-code.cli:${claudeExe}`,
        instanceLabel: 'Claude Code CLI',
        executablePath: claudeExe,
        terminalIdentifier: 'terminal-1',
      },
    })
    endpointIDs.claudeCode = endpoint.id
  }
  if (codexExe !== undefined) {
    const desktop = codexExe.toLowerCase().includes('.app/contents/')
    const endpoint = service.registerEndpoint({
      runtimeTypeID: 'openai.codex/app-server',
      displayName: desktop ? 'Codex (Desktop)' : 'Codex (local)',
      runtimeVersion: 'local',
      location: 'local',
      instanceIdentity: {
        provider: { rawValue: 'codex' },
        surfaceKind: desktop ? 'desktop_application' : 'terminal_cli',
        identityBasis: 'installation',
        stableInstanceKey: `codex.app-server:${codexExe}`,
        instanceLabel: desktop ? 'Codex Desktop' : 'Codex CLI',
        executablePath: codexExe,
      },
    })
    endpointIDs.codex = endpoint.id
  }
  if (Object.keys(endpointIDs).length === 0) {
    throw MuError.capabilityMissing(
      'No runtime executables found. Install Claude Code or Codex, or inject executable paths.',
    )
  }

  // Keep the first user turn out of the cold-start path. This is best effort;
  // an unavailable runtime is still surfaced by the normal probe/turn path.
  void service.warmEndpoints()

  return {
    service,
    store,
    harness,
    agentIDs: {},
    endpointIDs,
  }
}

export async function bootstrapWithProbes(
  options: BootstrapLocalControlPlaneOptions,
): Promise<BootstrappedControlPlane> {
  const bootstrapped = bootstrapLocalControlPlane(options)
  await probeEndpoints(bootstrapped.store, bootstrapped.harness, options.now)
  return bootstrapped
}
