import { describe, expect, it } from 'vitest'
import { MuError } from '../src/errors.ts'
import { createLocalHarness } from '../src/harness/local-child-process.ts'
import { createQMHarness } from '../src/harness/qm-http.ts'
import { toAgentHostAdapter } from '../src/host-adapter/harness-adapter.ts'
import type { AgentHostAdapter, HostApprovalResolution } from '../src/host-adapter/types.ts'
import { uuid } from '../src/identity.ts'
import { createTaskRecord } from '../src/models.ts'
import { createProjectContextPackRecord } from '../src/project-kernel/index.ts'
import { CLAUDE_CODE_PROVIDER } from '../src/types.ts'
import type { Harness, HarnessTurnEvent } from '../src/harness/types.ts'

// ---------------------------------------------------------------------------
// Mock harness
// ---------------------------------------------------------------------------

function mockHarness(): Harness {
  return {
    capabilities: {
      mode: 'local',
      providers: [{ rawValue: 'claude_code' }],
      controlMode: 'managed',
      observationFidelity: 'native_stream',
      supportsInterrupt: true,
      supportsArtifacts: true,
      supportsEventStream: true,
      notes: [],
    },
    async *runTurn() {
      yield { kind: 'session_started', sessionID: 'mock-1' }
      yield { kind: 'visible_text', text: 'Hello from the host.' }
      yield { kind: 'completed', result: { status: 'success', sessionID: 'mock-1', output: 'Hello from the host.' } }
    },
    async interrupt() {},
    async probe() {
      return { ok: true, mode: 'local', message: 'ok', latencyMilliseconds: 0 }
    },
    async listArtifacts() {
      return []
    },
  }
}

function taskAndPack() {
  const task = createTaskRecord({ title: 'T', objective: 'O', repositoryPath: '/tmp/repo' })
  const pack = createProjectContextPackRecord({
    projectID: uuid(),
    taskID: task.id,
    workspaceID: uuid(),
    objective: 'O',
    contentSHA256: '0'.repeat(64),
  })
  return { task, pack }
}

async function collect(host: AgentHostAdapter) {
  const { task, pack } = taskAndPack()
  const events: HarnessTurnEvent[] = []
  for await (const event of host.submit({ provider: CLAUDE_CODE_PROVIDER, task, contextPack: pack, text: 'Go.' })) {
    events.push(event)
  }
  return events
}

describe('AgentHostAdapter contract', () => {
  it('exposes the seven contract capabilities', () => {
    const host = toAgentHostAdapter(mockHarness(), { hostID: 'claude-code.cli' })
    expect(host.hostID).toBe('claude-code.cli')
    const c = host.capabilities
    // probe / submit / events / interrupt / approvals / artifacts / delivery
    expect(typeof host.probe).toBe('function')
    expect(typeof host.submit).toBe('function')
    expect(typeof host.interrupt).toBe('function')
    expect(typeof host.listArtifacts).toBe('function')
    expect(c.supportsEventStream).toBe(true)
    expect(c.supportsInterrupt).toBe(true)
    expect(c.supportsArtifacts).toBe(true)
    expect(c.approvals).toBe('report_only')
    expect(c.deliveryReceipt).toBe(false)
  })

  it('defaults hostID from the harness mode', () => {
    expect(toAgentHostAdapter(mockHarness()).hostID).toBe('mu.local-harness')
    expect(toAgentHostAdapter(createQMHarness({ baseURL: 'http://x', sourceSecret: 's'.repeat(40) })).hostID).toBe('qm.bridge')
  })

  it('streams submit events identically to the underlying harness', async () => {
    const host = toAgentHostAdapter(mockHarness())
    const events = await collect(host)
    expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'mock-1' })
    expect(events[1]).toEqual({ kind: 'visible_text', text: 'Hello from the host.' })
    expect(events.at(-1)?.kind).toBe('completed')
  })

  it('forwards interrupt and listArtifacts', async () => {
    let interrupted = false
    const harness: Harness = {
      capabilities: mockHarness().capabilities,
      async *runTurn() {
        yield { kind: 'cancelled' }
      },
      async interrupt() {
        interrupted = true
      },
      async probe() {
        return { ok: true, mode: 'local', message: 'ok', latencyMilliseconds: 0 }
      },
      async listArtifacts(sessionID) {
        return [{ name: 'a.txt', relativePath: 'a.txt', kind: 'text/plain', byteCount: 1, nativeRef: sessionID }]
      },
    }
    const host = toAgentHostAdapter(harness)
    await host.interrupt('s-1')
    expect(interrupted).toBe(true)
    const artifacts = await host.listArtifacts('s-1')
    expect(artifacts).toHaveLength(1)
    expect(artifacts[0]?.name).toBe('a.txt')
  })

  it('exposes stop() when the harness has one', () => {
    const harness = mockHarness()
    let stopped = false
    const adapter = toAgentHostAdapter(Object.assign(harness, { stop: () => { stopped = true } }))
    adapter.stop?.()
    expect(stopped).toBe(true)
  })

  it('exposes resolveApproval only with resolve_forward support', async () => {
    const resolution: HostApprovalResolution = { sessionID: 's-1', requestID: 'req-1', decision: 'granted' }
    const received: HostApprovalResolution[] = []
    const host = toAgentHostAdapter(mockHarness(), {
      approvals: 'resolve_forward',
      resolveApproval: async (r) => {
        received.push(r)
      },
    })
    expect(host.capabilities.approvals).toBe('resolve_forward')
    await host.resolveApproval?.(resolution)
    expect(received).toEqual([resolution])
  })

  it('rejects resolve_forward without an implementation', () => {
    expect(() => toAgentHostAdapter(mockHarness(), { approvals: 'resolve_forward' })).toThrow(MuError)
  })

  it('works end-to-end through the control plane as an explicit host', async () => {
    const fsMod = await import('node:fs')
    const osMod = await import('node:os')
    const pathMod = await import('node:path')
    const { SQLiteStore } = await import('../src/persistence/store.ts')
    const { createControlPlaneService } = await import('../src/control-plane/service.ts')

    const dataDirectory = fsMod.default.mkdtempSync(pathMod.default.join(osMod.default.tmpdir(), 'mu-host-'))
    const store = new SQLiteStore({ dataDirectory, filename: ':memory:' })
    const host = toAgentHostAdapter(mockHarness(), { hostID: 'mock.host' })
    const service = createControlPlaneService({ store, harness: mockHarness(), host })
    try {
      const project = service.createProject({ displayName: 'Host Project', ownerPrincipalID: uuid() })
      service.registerEndpoint({ runtimeTypeID: 'mock', displayName: 'Mock host', runtimeVersion: '1', location: 'local' })
      const task = service.createTask({
        projectID: project.id,
        title: 'Host task',
        objective: 'Verify the host contract',
        repositoryPath: '/tmp/repo',
      })
      const events = []
      for await (const event of service.runTaskTurn({ taskID: task.id, text: 'Go.' })) {
        events.push(event)
      }
      expect(service.fetchTask(task.id)?.status).toBe('completed')
      expect(service.listChatEntries(task.id).find((e) => e.authorKind === 'agent')?.text).toContain('host')
    } finally {
      fsMod.default.rmSync(dataDirectory, { recursive: true, force: true })
    }
  })
})
