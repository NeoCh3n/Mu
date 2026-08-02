import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { bootstrapLocalControlPlane } from '../src/control-plane/bootstrap.ts'
import {
  createControlPlaneService,
  type ControlPlaneService,
} from '../src/control-plane/service.ts'
import {
  fetchContextConflicts,
  fetchContextRecords,
} from '../src/control-plane/context.ts'
import { fetchLedger } from '../src/control-plane/ledger.ts'
import { MuError } from '../src/errors.ts'
import type { Harness, HarnessTurnEvent } from '../src/harness/types.ts'
import { uuid, type UUID } from '../src/identity.ts'
import { createRuntimeEndpoint, isUsefulRuntimeEndpoint } from '../src/models.ts'
import { upsertEndpoint } from '../src/persistence/domain.ts'
import { SQLiteStore } from '../src/persistence/store.ts'

// ---------------------------------------------------------------------------
// Mock harness: streams a deterministic turn without any process or network.
// ---------------------------------------------------------------------------

function mockHarness(): Harness & { interrupted: () => number } {
  let interrupts = 0
  const harness: Harness = {
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
      yield { kind: 'session_started', sessionID: 'mock-session-1' }
      yield { kind: 'visible_text', text: 'Mock analysis of the renderer.\n' }
      yield { kind: 'visible_text', text: 'Recommendation: optimize the queue.' }
      yield {
        kind: 'completed',
        result: {
          status: 'success',
          sessionID: 'mock-session-1',
          output: 'Mock analysis of the renderer.\nRecommendation: optimize the queue.',
          model: 'mock-model',
        },
      }
    },
    async interrupt() {
      interrupts += 1
    },
    async probe() {
      return {
        ok: true,
        mode: 'local',
        runtimeVersion: 'mock-1.0',
        loggedIn: true,
        message: 'Mock harness is available.',
        latencyMilliseconds: 1,
      }
    },
    async listArtifacts(sessionID) {
      if (sessionID !== 'mock-session-1') return []
      return [
        { name: 'report.md', relativePath: 'report.md', kind: 'text/markdown', byteCount: 12, nativeRef: 'art-1' },
      ]
    },
  }
  return Object.assign(harness, { interrupted: () => interrupts })
}

function harnessWithScript(
  script: Array<HarnessTurnEvent>,
  artifacts: Harness['listArtifacts'] = async () => [],
): Harness {
  return {
    capabilities: mockHarness().capabilities,
    async *runTurn() {
      for (const event of script) yield event
    },
    async interrupt() {},
    async probe() {
      return { ok: true, mode: 'local', message: 'ok', latencyMilliseconds: 0 }
    },
    listArtifacts: artifacts,
  }
}

// ---------------------------------------------------------------------------
// Fixture: store + service
// ---------------------------------------------------------------------------

function makeService(harness: Harness = mockHarness()): {
  service: ControlPlaneService
  store: SQLiteStore
  cleanup: () => void
} {
  const dataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-cp-'))
  const store = new SQLiteStore({ dataDirectory, filename: ':memory:' })
  const service = createControlPlaneService({ store, harness })
  return {
    service,
    store,
    cleanup: () => fs.rmSync(dataDirectory, { recursive: true, force: true }),
  }
}

function seedTask(service: ControlPlaneService): {
  projectID: UUID
  taskID: UUID
  agentID: UUID
  endpointID: UUID
} {
  const project = service.createProject({
    displayName: 'Renderer Project',
    ownerPrincipalID: uuid(),
  })
  const agent = service.createAgent({
    displayName: 'Builder',
    shortName: 'builder',
    role: 'builder',
    summary: 'Implements task work.',
  })
  const endpoint = service.registerEndpoint({
    runtimeTypeID: 'anthropic.claude-code/cli',
    displayName: 'Claude Code (test)',
    runtimeVersion: 'test',
    location: 'local',
  })
  const task = service.createTask({
    projectID: project.id,
    title: 'Optimize the renderer',
    objective: 'Review and optimize the frame queue.',
    repositoryPath: '/tmp/mu-renderer',
    assignedAgentIdentityID: agent.id,
    requestedByActorID: uuid(),
    constraints: ['Stay read-only.'],
  })
  return { projectID: project.id, taskID: task.id, agentID: agent.id, endpointID: endpoint.id }
}

async function runTurn(service: ControlPlaneService, taskID: UUID, text = 'Analyze the renderer.') {
  const events = []
  for await (const event of service.runTaskTurn({ taskID, text })) {
    events.push(event)
  }
  return events
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('ControlPlaneService', () => {
  it('creates projects, agents, endpoints, and tasks with ledger events', () => {
    const { service, cleanup } = makeService()
    try {
      const project = service.createProject({ displayName: 'P1', ownerPrincipalID: uuid() })
      const agent = service.createAgent({ displayName: 'A1', shortName: 'a1', role: 'builder', summary: 's' })
      const endpoint = service.registerEndpoint({
        runtimeTypeID: 'anthropic.claude-code/cli',
        displayName: 'Claude Code',
        runtimeVersion: '1.0',
        location: 'local',
      })
      const task = service.createTask({
        projectID: project.id,
        title: 'T1',
        objective: 'Do the thing',
        repositoryPath: '/tmp/repo',
        assignedAgentIdentityID: agent.id,
      })

      expect(service.listProjects()).toHaveLength(1)
      expect(service.listAgents()).toHaveLength(1)
      expect(service.listEndpoints()).toHaveLength(1)
      expect(service.listTasks()).toHaveLength(1)
      expect(service.fetchTask(task.id)?.status).toBe('ready')
      expect(endpoint.status).toBe('discovered')
      expect(endpoint.instanceIdentity).toBeUndefined()
      expect(isUsefulRuntimeEndpoint(endpoint)).toBe(false)

      const ledger = service.fetchLedger()
      expect(ledger.map((e) => e.type)).toEqual(
        expect.arrayContaining(['project.created', 'agent.created', 'endpoint.registered', 'task.created']),
      )
    } finally {
      cleanup()
    }
  })

  it('runs a full turn: lease, pack, binding, chat, artifacts, terminal states', async () => {
    const harness = mockHarness()
    const { service, cleanup } = makeService(harness)
    try {
      const { taskID } = seedTask(service)
      const events = await runTurn(service, taskID, 'Analyze the renderer.')

      // Harness events stream through the generator.
      expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'mock-session-1' })
      expect(events.some((e) => e.kind === 'visible_text')).toBe(true)
      const completed = events.find((e) => e.kind === 'completed')
      expect(completed?.kind).toBe('completed')

      // Task terminal state.
      expect(service.fetchTask(taskID)?.status).toBe('completed')

      // Run + binding.
      const runs = service.listRuns(taskID)
      expect(runs).toHaveLength(1)
      expect(runs[0]?.state).toBe('completed')
      expect(runs[0]?.nativeOutput).toContain('optimize the queue')
      const bindings = service.listSessionBindings(taskID)
      expect(bindings[0]?.nativeSessionID).toBe('mock-session-1')
      expect(bindings[0]?.state).toBe('completed')

      // Chat entries: user + agent.
      const chat = service.listChatEntries(taskID)
      expect(chat).toHaveLength(2)
      expect(chat.find((c) => c.authorKind === 'user')?.text).toBe('Analyze the renderer.')
      const agentChat = chat.find((c) => c.authorKind === 'agent')
      expect(agentChat?.authorName).toBe('Builder')
      expect(agentChat?.text).toContain('Recommendation')

      // Artifacts harvested from the harness.
      const artifacts = service.listRuntimeArtifacts(taskID)
      expect(artifacts).toHaveLength(1)
      expect(artifacts[0]?.name).toBe('report.md')

      // Ledger.
      const ledger = service.fetchLedger(taskID)
      expect(ledger.map((e) => e.type)).toEqual(
        expect.arrayContaining(['task.run_started', 'task.run_completed']),
      )
    } finally {
      cleanup()
    }
  })

  it('summarizes a placeholder task title from its first message', async () => {
    const { service, cleanup } = makeService()
    try {
      const project = service.createProject({ displayName: 'Title Project', ownerPrincipalID: uuid() })
      const endpoint = service.registerEndpoint({
        runtimeTypeID: 'anthropic.claude-code/cli',
        displayName: 'Claude Code',
        runtimeVersion: '1.0',
        location: 'local',
      })
      const task = service.createTask({
        projectID: project.id,
        title: 'New task',
        objective: 'Start working in Title Project.',
        repositoryPath: '/tmp/mu-title-project',
      })
      await runTurn(service, task.id, '@Claude Code inspect the login flow and add a regression test.')

      expect(service.fetchTask(task.id)?.title).toBe('inspect the login flow and add a regression test')
      expect(service.fetchLedger().some((event) => event.type === 'task.auto_titled')).toBe(true)
      expect(endpoint.status).toBe('discovered')
    } finally {
      cleanup()
    }
  })

  it('persists and delivers an immutable Context Pack to a second task', async () => {
    const { service, cleanup } = makeService()
    try {
      const { projectID, taskID, agentID, endpointID } = seedTask(service)
      const actor = uuid()
      const record = service.importContextRecord({
        projectID,
        taskID,
        kind: 'finding',
        subject: 'accepted-fact',
        text: 'The source runtime reported 60 FPS.',
        sourceActorID: actor,
      })
      service.reviewContextRecord({ recordID: record.id, decision: 'accepted', actorID: actor })
      const pack = service.buildContextPack({
        projectID,
        taskID,
        workspaceID: projectID,
        objective: 'Review the source runtime.',
        endpointID,
        actorID: actor,
        principalID: actor,
      })
      const target = service.createTask({
        projectID,
        title: 'Review through another host',
        objective: 'Validate the imported source fact.',
        repositoryPath: '/tmp/mu-renderer',
        assignedAgentIdentityID: agentID,
        requestedByActorID: actor,
      })
      const selectedForTarget = service.buildContextPack({
        projectID,
        taskID: target.id,
        workspaceID: projectID,
        objective: target.objective,
        endpointID,
        actorID: actor,
        principalID: actor,
        contextRecordIDs: [record.id],
      })
      expect(selectedForTarget.includedContextRecordIDs).toEqual([record.id])
      for await (const _event of service.runTaskTurn({
        taskID: target.id,
        contextPackID: pack.id,
        text: 'Use the delivered source fact.',
      })) {
        // Consume the terminal event.
      }
      const run = service.listRuns(target.id)[0]
      expect(run?.contextPackID).toBe(pack.id)
      expect(service.fetchTask(target.id)?.status).toBe('completed')
    } finally {
      cleanup()
    }
  })

  it('marks tasks failed when the harness fails', async () => {
    const harness = harnessWithScript([
      { kind: 'session_started', sessionID: 's-1' },
      { kind: 'failed', errorMessage: 'Claude Code exited with status 1.' },
    ])
    const { service, cleanup } = makeService(harness)
    try {
      const { taskID } = seedTask(service)
      await runTurn(service, taskID)
      expect(service.fetchTask(taskID)?.status).toBe('failed')
      expect(service.listRuns(taskID)[0]?.state).toBe('failed')
      expect(service.fetchLedger(taskID).some((e) => e.type === 'task.run_failed')).toBe(true)
    } finally {
      cleanup()
    }
  })

  it('creates approval interactions for pending-approval turns', async () => {
    const harness = harnessWithScript([
      { kind: 'session_started', sessionID: 's-2' },
      {
        kind: 'pending_approval',
        approvals: [{ requestID: 'req-1', command: 'Bash', reason: 'command execution' }],
      },
      {
        kind: 'completed',
        result: {
          status: 'pending_approval',
          sessionID: 's-2',
          output: '',
          pendingApprovals: [{ requestID: 'req-1', command: 'Bash', reason: 'command execution' }],
        },
      },
    ])
    const { service, cleanup } = makeService(harness)
    try {
      const { taskID } = seedTask(service)
      await runTurn(service, taskID)
      expect(service.fetchTask(taskID)?.status).toBe('blocked')
      expect(service.listRuns(taskID)[0]?.state).toBe('blocked')
      expect(service.listSessionBindings(taskID)[0]?.state).toBe('awaiting_approval')
      expect(service.fetchLedger(taskID).some((e) => e.type === 'task.approval_requested')).toBe(true)
    } finally {
      cleanup()
    }
  })

  it('interrupts a running turn and records cancellation', async () => {
    let interrupted = false
    const harness: Harness = {
      capabilities: mockHarness().capabilities,
      async *runTurn() {
        yield { kind: 'session_started', sessionID: 'slow-1' }
        while (!interrupted) {
          await new Promise((resolve) => setTimeout(resolve, 10))
        }
        yield { kind: 'cancelled' }
      },
      async interrupt() {
        interrupted = true
      },
      async probe() {
        return { ok: true, mode: 'local', message: 'ok', latencyMilliseconds: 0 }
      },
      async listArtifacts() {
        return []
      },
    }
    const { service, cleanup } = makeService(harness)
    try {
      const { taskID } = seedTask(service)
      const iterator = service.runTaskTurn({ taskID, text: 'Go.' })
      for await (const event of iterator) {
        if (event.kind === 'session_started') {
          const run = service.listRuns(taskID)[0]!
          await service.interruptRun(run.id)
        }
      }
      expect(service.fetchTask(taskID)?.status).toBe('cancelled')
      expect(service.listRuns(taskID)[0]?.state).toBe('cancelled')
      expect(service.fetchLedger(taskID).some((e) => e.type === 'task.run_cancelled')).toBe(true)
    } finally {
      cleanup()
    }
  })

  it('imports, reviews, conflicts, and resolves context records', () => {
    const { service, store, cleanup } = makeService()
    try {
      const { projectID, taskID } = seedTask(service)
      const actor = uuid()
      const first = service.importContextRecord({
        projectID,
        taskID,
        kind: 'fact',
        subject: 'frame-rate',
        text: 'Frame rate is 60 FPS.',
        sourceActorID: actor,
      })
      service.reviewContextRecord({ recordID: first.id, decision: 'accepted', actorID: actor })

      // Conflicting claim on the same subject creates a conflict.
      const second = service.importContextRecord({
        projectID,
        taskID,
        kind: 'fact',
        subject: 'frame-rate',
        text: 'Frame rate is 120 FPS.',
        sourceActorID: actor,
      })

      const conflicts = fetchContextConflicts(store, projectID)
      expect(conflicts).toHaveLength(1)
      expect(conflicts[0]?.recordIDs).toEqual(expect.arrayContaining([first.id, second.id]))

      // Resolve: keep the first, supersede the second.
      service.resolveConflict({
        conflictID: conflicts[0]!.id,
        acceptedRecordIDs: [first.id],
        actorID: actor,
      })
      const records = fetchContextRecords(store, projectID)
      expect(records.find((r) => r.id === first.id)?.status).toBe('accepted')
      expect(records.find((r) => r.id === second.id)?.status).toBe('rejected')

      // Pack building includes only accepted records.
      const pack = service.buildContextPack({
        projectID,
        taskID,
        workspaceID: projectID,
        objective: 'Review the renderer',
        endpointID: uuid(),
        actorID: actor,
        principalID: uuid(),
      })
      expect(pack.includedContextRecordIDs).toEqual([first.id])
      expect(pack.contentSHA256).toMatch(/^[0-9a-f]{64}$/)
      expect(pack.renderedContextMarkdown).toContain('Frame rate is 60 FPS.')
    } finally {
      cleanup()
    }
  })

  it('manages approvals, reviews, and handoffs', () => {
    const { service, cleanup } = makeService()
    try {
      const { projectID, taskID, agentID } = seedTask(service)
      const actor = uuid()

      const approval = service.requestApproval({
        projectID,
        taskID,
        scope: 'Bash',
        requestedByActorID: actor,
      })
      expect(approval.decision).toBe('pending')
      const granted = service.resolveApproval({
        approvalID: approval.id,
        decision: 'granted',
        approverActorID: actor,
      })
      expect(granted.decision).toBe('granted')
      expect(() =>
        service.resolveApproval({ approvalID: approval.id, decision: 'denied', approverActorID: actor }),
      ).toThrow(MuError)

      const review = service.submitReview({
        projectID,
        taskID,
        reviewerActorID: agentID,
        verdict: 'approved',
        findings: ['Looks good.'],
      })
      expect(review.verdict).toBe('approved')

      const endpointA = service.listEndpoints()[0]!
      const handoff = service.proposeHandoff({
        taskID,
        sourceEndpointID: endpointA.id,
        receiverEndpointID: endpointA.id,
        validationMessage: 'Handoff checkpoint.',
      })
      expect(handoff.status).toBe('proposed')
      const resolved = service.resolveHandoff({
        handoffID: handoff.id,
        accepted: true,
        validationMessage: 'Received.',
      })
      expect(resolved.status).toBe('accepted')
      expect(service.listHandoffs(taskID)).toHaveLength(1)
      expect(service.listHandoffs(taskID)[0]?.status).toBe('accepted')
    } finally {
      cleanup()
    }
  })

  it('probes endpoints and persists active status', async () => {
    const harness = mockHarness()
    const { service, store, cleanup } = makeService(harness)
    try {
      seedTask(service)
      const outcomes = await service.probeEndpoints()
      expect(outcomes).toHaveLength(1)
      expect(outcomes[0]?.ok).toBe(true)
      expect(service.listEndpoints()[0]?.status).toBe('active')
      expect(fetchLedger(store).some((e) => e.type === 'endpoint.probed')).toBe(true)
    } finally {
      cleanup()
    }
  })

  it('removes a runtime from scheduling while preserving its historical snapshot', () => {
    const { service, cleanup } = makeService()
    try {
      const endpoint = service.registerEndpoint({
        runtimeTypeID: 'anthropic.claude-code/cli',
        displayName: 'Claude Code (removable)',
        runtimeVersion: 'test',
        location: 'local',
      })

      const removed = service.removeEndpoint(endpoint.id)
      expect(removed.id).toBe(endpoint.id)
      expect(service.listEndpoints()).toEqual([])
      expect(() => service.removeEndpoint(endpoint.id)).toThrow(MuError)
    } finally {
      cleanup()
    }
  })

  it('closes only redundant low-confidence discoveries and keeps the newest copy', () => {
    const { service, store, cleanup } = makeService()
    try {
      const older = createRuntimeEndpoint({
        id: uuid(),
        runtimeTypeID: 'local.unknown',
        displayName: 'Unverified Runtime',
        adapterVersion: '1.0.0',
        runtimeVersion: 'unknown',
        location: 'local',
        provenance: 'vendor_cli',
        permissionModel: 'fine_grained',
        status: 'discovered',
        guaranteeNote: 'discovered',
        lastProbedAt: new Date('2026-08-01T00:00:00.000Z'),
      })
      const newest = createRuntimeEndpoint({
        ...older,
        id: uuid(),
        lastProbedAt: new Date('2026-08-02T00:00:00.000Z'),
      })
      const distinct = createRuntimeEndpoint({
        ...older,
        id: uuid(),
        displayName: 'Another Runtime',
      })
      upsertEndpoint(store, older)
      upsertEndpoint(store, newest)
      upsertEndpoint(store, distinct)

      const removedIDs = service.removeDuplicateDiscoveredEndpoints()
      expect(removedIDs).toEqual([older.id])
      expect(service.listEndpoints().map((endpoint) => endpoint.id)).toEqual(
        expect.arrayContaining([newest.id, distinct.id]),
      )
      expect(fetchLedger(store).at(-1)?.payload.reason).toBe('duplicate_discovery')
    } finally {
      cleanup()
    }
  })

  it('rejects empty turn text', async () => {
    const { service, cleanup } = makeService()
    try {
      const { taskID } = seedTask(service)
      await expect(runTurn(service, taskID, '')).rejects.toThrow(MuError)
    } finally {
      cleanup()
    }
  })
})

// ---------------------------------------------------------------------------
// Bootstrap: the harness must be wired to the same executables its endpoints
// advertise (regression: endpoint registered but harness unconfigured).
// ---------------------------------------------------------------------------

describe('bootstrapLocalControlPlane', () => {
  it('runs a real turn through the bootstrapped harness and endpoint', async () => {
    const FAKE_CLAUDE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'support/fake-claude.mjs')
    fs.chmodSync(FAKE_CLAUDE, 0o755)
    const repositoryPath = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-boot-'))
    const dataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-boot-data-'))
    try {
      const bootstrapped = bootstrapLocalControlPlane({
        dataDirectory,
        filename: ':memory:',
        claudeCodeExecutable: FAKE_CLAUDE,
      })
      expect(bootstrapped.endpointIDs.claudeCode).toBeTruthy()
      expect(bootstrapped.harness.capabilities.providers).toContainEqual({ rawValue: 'claude_code' })

      const project = bootstrapped.service.createProject({
        displayName: 'Boot',
        ownerPrincipalID: 'local-user' as never,
      })
      const task = bootstrapped.service.createTask({
        projectID: project.id,
        title: 'Boot task',
        objective: 'Verify bootstrap wiring',
        repositoryPath,
      })
      const events = []
      for await (const event of bootstrapped.service.runTaskTurn({ taskID: task.id, text: 'Go.' })) {
        events.push(event)
      }
      expect(bootstrapped.service.fetchTask(task.id)?.status).toBe('completed')
      const runs = bootstrapped.service.listRuns(task.id)
      expect(runs[0]?.state).toBe('completed')
      expect(runs[0]?.nativeOutput).toContain('renderer')
      expect(events.at(-1)?.kind).toBe('chat_entry')
    } finally {
      fs.rmSync(repositoryPath, { recursive: true, force: true })
      fs.rmSync(dataDirectory, { recursive: true, force: true })
    }
  })
})
