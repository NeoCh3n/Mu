import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import type { FastifyInstance } from 'fastify'
import { describe, expect, it } from 'vitest'
import { buildApp, type MuApp } from '../src/wiring.ts'
import { mockHarness } from './support/mock-harness.ts'

function makeApp(overrides: { filename?: string; harness?: ReturnType<typeof mockHarness> } = {}): {
  mu: MuApp
  cleanup: () => void
} {
  const dataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-server-'))
  const mu = buildApp({
    dataDirectory,
    filename: overrides.filename ?? ':memory:',
    harness: overrides.harness ?? mockHarness(),
  })
  return {
    mu,
    cleanup: () => {
      void mu.close()
      fs.rmSync(dataDirectory, { recursive: true, force: true })
    },
  }
}

async function seedProjectAndTask(app: FastifyInstance): Promise<{ projectID: string; taskID: string }> {
  const projectResponse = await app.inject({
    method: 'POST',
    url: '/projects',
    payload: { displayName: 'Server Project' },
  })
  const project = projectResponse.json<{ project: { id: string } }>()
  const taskResponse = await app.inject({
    method: 'POST',
    url: '/tasks',
    payload: {
      projectID: project.project.id,
      title: 'Server task',
      objective: 'Verify the server flows.',
      repositoryPath: '/tmp/mu-server-repo',
    },
  })
  const task = taskResponse.json<{ task: { id: string } }>()
  return { projectID: project.project.id, taskID: task.task.id }
}

/** Polls until a condition holds or the deadline passes. */
async function waitFor(
  condition: () => boolean | Promise<boolean>,
  timeoutMs = 5000,
  intervalMs = 20,
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error('waitFor timed out.')
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }
}

describe('Mu HTTP API', () => {
  it('serves /health with the harness mode', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const response = await mu.app.inject({ method: 'GET', url: '/health' })
      expect(response.statusCode).toBe(200)
      const body = response.json<{ ok: boolean; mode: string }>()
      expect(body.ok).toBe(true)
      expect(body.mode).toBe('local')
    } finally {
      cleanup()
    }
  })

  it('creates projects, agents, endpoints, and tasks', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const { app } = mu
      const projects = await app.inject({ method: 'GET', url: '/projects' })
      expect(projects.json<{ projects: unknown[] }>().projects).toHaveLength(0)

      await app.inject({ method: 'POST', url: '/projects', payload: { displayName: 'P1' } })
      await app.inject({
        method: 'POST',
        url: '/agents',
        payload: { displayName: 'Builder', shortName: 'builder', role: 'builder', summary: 's' },
      })
      await app.inject({
        method: 'POST',
        url: '/endpoints',
        payload: { runtimeTypeID: 'anthropic.claude-code/cli', displayName: 'Claude Code', runtimeVersion: '1.0', location: 'local' },
      })
      const taskResponse = await app.inject({
        method: 'POST',
        url: '/tasks',
        payload: {
          projectID: '00000000-0000-4000-8000-000000000001',
          title: 'T1',
          objective: 'Do it',
          repositoryPath: '/tmp/repo',
        },
      })
      expect(taskResponse.statusCode).toBe(200)

      const tasks = await app.inject({ method: 'GET', url: '/tasks' })
      expect(tasks.json<{ tasks: unknown[] }>().tasks).toHaveLength(1)
      const agents = await app.inject({ method: 'GET', url: '/agents' })
      expect(agents.json<{ agents: unknown[] }>().agents).toHaveLength(1)
      const endpoints = await app.inject({ method: 'GET', url: '/endpoints' })
      expect(endpoints.json<{ endpoints: unknown[] }>().endpoints).toHaveLength(2)
    } finally {
      cleanup()
    }
  })

  it('runs a full turn over the API and persists chat', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const { app } = mu
      const { taskID } = await seedProjectAndTask(app)

      const turnResponse = await app.inject({
        method: 'POST',
        url: `/tasks/${taskID}/turns`,
        payload: { text: 'Analyze the renderer.' },
      })
      expect(turnResponse.statusCode).toBe(200)
      const turn = turnResponse.json<{ runID: string; taskID: string; state: string }>()
      expect(turn.runID).toBeTruthy()

      // The background turn completes; chat gains the agent entry.
      await waitFor(() => {
        return app
          .inject({ method: 'GET', url: `/tasks/${taskID}/chat` })
          .then((r) => r.json<{ entries: Array<{ authorKind: string }> }>().entries.some((e) => e.authorKind === 'agent'))
      })
      const chat = await app.inject({ method: 'GET', url: `/tasks/${taskID}/chat` })
      const entries = chat.json<{ entries: Array<{ authorKind: string; text: string }> }>().entries
      expect(entries).toHaveLength(2)
      expect(entries.find((e) => e.authorKind === 'user')?.text).toBe('Analyze the renderer.')
      expect(entries.find((e) => e.authorKind === 'agent')?.text).toContain('ship it')

      // Runs + ledger endpoints.
      const runs = await app.inject({ method: 'GET', url: `/tasks/${taskID}/runs` })
      expect(runs.json<{ runs: Array<{ state: string }> }>().runs[0]?.state).toBe('completed')
      const ledger = await app.inject({ method: 'GET', url: `/tasks/${taskID}/ledger` })
      const types = ledger.json<{ events: Array<{ type: string }> }>().events.map((e) => e.type)
      expect(types).toEqual(expect.arrayContaining(['task.run_started', 'task.run_completed']))
    } finally {
      cleanup()
    }
  })

  it('rejects turns with empty text', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const { taskID } = await seedProjectAndTask(mu.app)
      const response = await mu.app.inject({
        method: 'POST',
        url: `/tasks/${taskID}/turns`,
        payload: { text: '   ' },
      })
      expect(response.statusCode).toBe(400)
    } finally {
      cleanup()
    }
  })

  it('imports and reviews context records over the API', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const { app } = mu
      const { projectID, taskID } = await seedProjectAndTask(app)
      const imported = await app.inject({
        method: 'POST',
        url: '/context/import',
        payload: { projectID, taskID, kind: 'fact', subject: 'renderer-frame-rate', text: '60 FPS' },
      })
      expect(imported.statusCode).toBe(200)
      const record = imported.json<{ record: { id: string; status: string } }>().record
      expect(record.status).toBe('candidate')

      const reviewed = await app.inject({
        method: 'POST',
        url: `/context/${record.id}/review`,
        payload: { decision: 'accepted' },
      })
      expect(reviewed.statusCode).toBe(200)
      expect(reviewed.json<{ record: { status: string } }>().record.status).toBe('accepted')

      const context = await app.inject({ method: 'GET', url: `/tasks/${taskID}/context` })
      expect(context.json<{ records: Array<{ status: string }> }>().records[0]?.status).toBe('accepted')
    } finally {
      cleanup()
    }
  })

  it('resolves approvals and handoffs over the API', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const { app } = mu
      const { projectID, taskID } = await seedProjectAndTask(app)

      // Approvals: request via the service (no create route in Phase 6) and
      // resolve over the API.
      const approval = mu.service.requestApproval({
        projectID: projectID as never,
        taskID: taskID as never,
        scope: 'Bash',
        requestedByActorID: 'local-user' as never,
      })
      const resolvedApproval = await app.inject({
        method: 'POST',
        url: `/approvals/${approval.id}/resolve`,
        payload: { decision: 'granted', approverActorID: 'local-user' },
      })
      expect(resolvedApproval.statusCode).toBe(200)
      expect(resolvedApproval.json<{ approval: { decision: string } }>().approval.decision).toBe('granted')

      // Handoffs.
      const endpoints = await app.inject({ method: 'GET', url: '/endpoints' })
      const endpointID = endpoints.json<{ endpoints: Array<{ id: string }> }>().endpoints[0]?.id
      const proposed = await app.inject({
        method: 'POST',
        url: '/handoffs',
        payload: { taskID, sourceEndpointID: endpointID, receiverEndpointID: endpointID, validationMessage: 'handoff' },
      })
      expect(proposed.statusCode).toBe(200)
      const handoff = proposed.json<{ handoff: { id: string; status: string } }>().handoff
      expect(handoff.status).toBe('proposed')

      const resolved = await app.inject({
        method: 'POST',
        url: `/handoffs/${handoff.id}/resolve`,
        payload: { accepted: true, validationMessage: 'ok' },
      })
      expect(resolved.statusCode).toBe(200)
      expect(resolved.json<{ handoff: { status: string } }>().handoff.status).toBe('accepted')
    } finally {
      cleanup()
    }
  })

  it('streams SSE events on /api/events', async () => {
    const { mu, cleanup } = makeApp()
    try {
      const events: string[] = []
      const sink = new Promise<void>((resolve) => {
        const unsubscribe = mu.hub.subscribe((envelope) => {
          events.push(envelope.event)
          if (envelope.event === 'turn_ended') {
            unsubscribe()
            resolve()
          }
        })
      })
      const { taskID } = await seedProjectAndTask(mu.app)
      await mu.app.inject({
        method: 'POST',
        url: `/tasks/${taskID}/turns`,
        payload: { text: 'Stream me.' },
      })
      await sink
      expect(events).toEqual(expect.arrayContaining(['turn', 'turn_event', 'turn_ended']))
    } finally {
      cleanup()
    }
  })

  it('interrupts a running turn via the API', async () => {
    let interrupted = false
    const hangingHarness = mockHarness()
    hangingHarness.runTurn = async function* () {
      yield { kind: 'session_started', sessionID: 'slow-session' }
      while (!interrupted) {
        await new Promise((resolve) => setTimeout(resolve, 10))
      }
      yield { kind: 'cancelled' }
    }
    hangingHarness.interrupt = async () => {
      interrupted = true
    }
    const { mu, cleanup } = makeApp({ harness: hangingHarness })
    try {
      const { taskID } = await seedProjectAndTask(mu.app)
      const turn = await mu.app.inject({
        method: 'POST',
        url: `/tasks/${taskID}/turns`,
        payload: { text: 'Long task.' },
      })
      const { runID } = turn.json<{ runID: string }>()
      await waitFor(() => mu.service.listRuns(taskID as never)[0]?.state === 'active')

      const response = await mu.app.inject({
        method: 'POST',
        url: `/tasks/${taskID}/interrupt`,
        payload: { runID },
      })
      expect(response.statusCode).toBe(200)
      await waitFor(() => mu.service.fetchTask(taskID as never)?.status === 'cancelled')
    } finally {
      cleanup()
    }
  })
})
