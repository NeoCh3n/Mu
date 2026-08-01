import type { Harness, HarnessTurnEvent } from '@mu/core'

/** Deterministic harness used by server integration tests. */
export function mockHarness(script?: Array<HarnessTurnEvent>): Harness {
  const events = script ?? [
    { kind: 'session_started', sessionID: 'mock-session-1' },
    { kind: 'visible_text', text: 'Server mock analysis.\n' },
    { kind: 'visible_text', text: 'Recommendation: ship it.' },
    {
      kind: 'completed',
      result: {
        status: 'success',
        sessionID: 'mock-session-1',
        output: 'Server mock analysis.\nRecommendation: ship it.',
      },
    },
  ] as Array<HarnessTurnEvent>
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
      for (const event of events) yield event
    },
    async interrupt() {},
    async probe() {
      return { ok: true, mode: 'local', runtimeVersion: 'mock', loggedIn: true, message: 'ok', latencyMilliseconds: 0 }
    },
    async listArtifacts() {
      return []
    },
  }
}
