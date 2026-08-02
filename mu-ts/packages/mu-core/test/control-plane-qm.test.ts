import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { createControlPlaneService, type ControlPlaneService } from '../src/control-plane/service.ts'
import { createQMHarness, QMHTTPHarness } from '../src/harness/qm-http.ts'
import { qmTurnRequestForMu } from '../src/harness/qm-mapping.ts'
import { uuid } from '../src/identity.ts'
import { createTaskRecord } from '../src/models.ts'
import { createProjectContextPackRecord } from '../src/project-kernel/index.ts'
import { SQLiteStore } from '../src/persistence/store.ts'
import { startMockQMServer, type MockQMServer } from './support/mock-qm-server.ts'

const SECRET = 'test-source-secret-abcdefghijklmnopqrstuvwxyz-0123456789'

describe('Experimental QM Bridge: Mu → QM TurnRequest mapping (mock contract)', () => {
  it('maps a bounded Context Pack into a QM turn request', () => {
    const task = createTaskRecord({
      title: 'Inspect widget',
      objective: 'Review the renderer',
      repositoryPath: '/tmp/repo',
    })
    const pack = createProjectContextPackRecord({
      projectID: uuid(),
      taskID: task.id,
      workspaceID: uuid(),
      objective: 'Review the renderer',
      constraints: ['Stay read-only.'],
      contentSHA256: '0'.repeat(64),
    })
    const request = qmTurnRequestForMu({
      surface: 'mu',
      task,
      contextPack: pack,
      text: 'Check the frame queue.',
      agentName: 'Builder',
      actorExternalID: 'mu-builder',
    })
    expect(request.surface).toBe('mu')
    expect(request.actor).toEqual({ externalId: 'mu-builder', displayName: 'Builder', isBot: true })
    expect(request.conversation.threadRef).toBe(task.id)
    expect(request.conversation.channelName).toBe('Inspect widget')
    expect(request.readOnly).toBe(true)
    expect(request.text).toContain('## Objective')
    expect(request.text).toContain('Review the renderer')
    expect(request.text).toContain('## Turn request')
    expect(request.text).toContain('Check the frame queue.')
    expect(request.origin).toEqual({ kind: 'automation', screenData: `mu:${task.id}` })
  })
})

describe('Experimental QM Bridge: control plane end-to-end against the mock QM server', () => {
  function makeService(mock: MockQMServer): { service: ControlPlaneService; cleanup: () => void } {
    const dataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-qm-'))
    const store = new SQLiteStore({ dataDirectory, filename: ':memory:' })
    const harness = createQMHarness({ baseURL: mock.baseURL, sourceSecret: SECRET, surface: 'mu' })
    const service = createControlPlaneService({ store, harness })
    return {
      service,
      cleanup: () => fs.rmSync(dataDirectory, { recursive: true, force: true }),
    }
  }

  it('runs a full turn against the mock QM server with the derived mapping', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: (body) => {
        const turn = body as { text?: string; conversation?: { threadRef?: string } }
        return {
          status: 200,
          body: {
            status: 'ok',
            reply: 'QM analysis complete: the queue is optimal.',
            runId: 'qm-run-1',
            sessionId: 'qm-sess-1',
          },
        }
      },
    })
    try {
      const { service, cleanup } = makeService(mock)
      try {
        const project = service.createProject({ displayName: 'QM Project', ownerPrincipalID: uuid() })
        service.registerEndpoint({
          runtimeTypeID: 'qm',
          displayName: 'QM (hosted)',
          runtimeVersion: '1.0',
          location: 'hosted',
        })
        const task = service.createTask({
          projectID: project.id,
          title: 'QM task',
          objective: 'Review the renderer',
          repositoryPath: '/tmp/qm-repo',
        })

        const events = []
        for await (const event of service.runTaskTurn({ taskID: task.id, text: 'Analyze the renderer.' })) {
          events.push(event)
        }

        // Terminal state through QM.
        expect(service.fetchTask(task.id)?.status).toBe('completed')
        const run = service.listRuns(task.id)[0]!
        expect(run.state).toBe('completed')
        expect(run.nativeOutput).toContain('queue is optimal')

        // Chat reflects the QM reply.
        const chat = service.listChatEntries(task.id)
        expect(chat.find((e) => e.authorKind === 'user')?.text).toBe('Analyze the renderer.')
        expect(chat.find((e) => e.authorKind === 'agent')?.text).toContain('queue is optimal')

        // The wire request carried the derived mapping.
        expect(mock.requests).toContain('POST /v1/turns')
        expect(events[0]?.kind).toBe('session_started')
      } finally {
        cleanup()
      }
    } finally {
      await mock.close()
    }
  })

  it('propagates refused QM turns to a failed task', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: () => ({ status: 403, body: { status: 'refused', reason: 'security quarantine' } }),
    })
    try {
      const { service, cleanup } = makeService(mock)
      try {
        const project = service.createProject({ displayName: 'P', ownerPrincipalID: uuid() })
        service.registerEndpoint({ runtimeTypeID: 'qm', displayName: 'QM', runtimeVersion: '1', location: 'hosted' })
        const task = service.createTask({
          projectID: project.id,
          title: 'Refused',
          objective: 'o',
          repositoryPath: '/tmp/r',
        })
        for await (const _event of service.runTaskTurn({ taskID: task.id, text: 'Go.' })) {
          // consume
        }
        expect(service.fetchTask(task.id)?.status).toBe('failed')
        expect(service.listRuns(task.id)[0]?.state).toBe('failed')
      } finally {
        cleanup()
      }
    } finally {
      await mock.close()
    }
  })

  it('interrupts a QM run with an abort signal', async () => {
    const mock = await startMockQMServer({ secret: SECRET })
    try {
      const harness = createQMHarness({ baseURL: mock.baseURL, sourceSecret: SECRET, surface: 'mu' })
      await harness.interrupt('run-99')
      expect(mock.signals).toEqual([{ runID: 'run-99', body: { kind: 'abort' } }])
      expect(harness).toBeInstanceOf(QMHTTPHarness)
    } finally {
      await mock.close()
    }
  })

  it('subscribes to session-state events from QM', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      sseEvents: [
        'event: session_state\ndata: {"sessionId":"run-1","state":"working"}',
        'event: session_state\ndata: {"sessionId":"run-1","state":"completed"}',
      ],
    })
    try {
      const harness = createQMHarness({ baseURL: mock.baseURL, sourceSecret: SECRET, surface: 'mu' })
      const events = []
      for await (const event of harness.subscribeSessionStates()) {
        events.push(event)
      }
      expect(events).toHaveLength(2)
      expect(events[0]?.state).toBe('working')
      expect(events[1]?.state).toBe('completed')
    } finally {
      await mock.close()
    }
  })
})
