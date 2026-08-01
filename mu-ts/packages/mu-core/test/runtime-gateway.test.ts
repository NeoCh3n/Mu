import { describe, expect, it } from 'vitest'
import { MuError } from '../src/errors.ts'
import { createRuntimeEndpoint, createTaskRecord } from '../src/models.ts'
import {
  adapterFor,
  endpointSupports,
  manifestFor,
  requireOperation,
} from '../src/runtime-gateway/index.ts'
import {
  AgentConnectionKind,
  AgentTrustLevel,
  RuntimeControlMode,
  RuntimeObservationFidelity,
  RuntimeOperationSupport,
} from '../src/runtime-gateway/manifest.ts'
import {
  claudeCodeRuntimeTypeID,
  codexRuntimeTypeID,
  RuntimeCapability,
} from '../src/types.ts'

function codexEndpoint(overrides: { status?: 'active' | 'offline' } = {}): ReturnType<typeof createRuntimeEndpoint> {
  return createRuntimeEndpoint({
    runtimeTypeID: codexRuntimeTypeID,
    displayName: 'Codex App Server',
    adapterVersion: '0.1',
    runtimeVersion: '0.1',
    location: 'local',
    provenance: 'vendor_protocol',
    permissionModel: 'fine_grained',
    capabilities: new Set([
      RuntimeCapability.start,
      RuntimeCapability.replan,
      RuntimeCapability.streamEvents,
    ]),
    status: overrides.status ?? 'active',
    guaranteeNote: 'official',
  })
}

describe('RuntimeGateway registry', () => {
  it('maps known runtime type IDs to builtin adapters', () => {
    expect(adapterFor(codexEndpoint())?.adapterID).toBe('mu.runtime.codex-app-server')
    expect(adapterFor(createRuntimeEndpoint({
      runtimeTypeID: claudeCodeRuntimeTypeID,
      displayName: 'Claude Code',
      adapterVersion: '0.1',
      runtimeVersion: '0.1',
      location: 'local',
      provenance: 'vendor_cli',
      permissionModel: 'prompt_gate',
      capabilities: new Set(),
      status: 'active',
      guaranteeNote: 'cli',
    }))?.adapterID).toBe('mu.runtime.claude-code-cli')
  })

  it('declares the Codex manifest with mirrored-stream fidelity', () => {
    const manifest = manifestFor(codexEndpoint())
    expect(manifest.connectionKind).toBe(AgentConnectionKind.managedRuntime)
    expect(manifest.controlMode).toBe(RuntimeControlMode.managedLimited)
    expect(manifest.trustLevel).toBe(AgentTrustLevel.managed)
    expect(manifest.observationFidelity).toBe(RuntimeObservationFidelity.mirroredStream)
    expect(manifest.operations).toHaveLength(17)
    expect(manifest.operations.filter((o) => o.support === RuntimeOperationSupport.supported)).toHaveLength(6)
    expect(manifest.operations.filter((o) => o.support === RuntimeOperationSupport.unsupported)).toHaveLength(2)
    expect(manifest.operations.find((o) => o.operation === 'approval.resolve')?.support).toBe('unsupported')
    expect(manifest.operations.find((o) => o.operation === 'artifact.list')?.support).toBe('unsupported')
  })

  it('falls back to an unimplemented manifest for unknown runtimes', () => {
    const unknown = createRuntimeEndpoint({
      runtimeTypeID: 'some.vendor/thing',
      displayName: 'Mystery',
      adapterVersion: '0.1',
      runtimeVersion: '0.1',
      location: 'remote',
      provenance: 'artifact_only',
      permissionModel: 'unknown',
      capabilities: new Set(),
      status: 'active',
      guaranteeNote: 'n/a',
    })
    const manifest = manifestFor(unknown)
    expect(manifest.adapterID).toBe('mu.runtime.unimplemented')
    expect(manifest.controlMode).toBe(RuntimeControlMode.submitOnly)
    expect(manifest.trustLevel).toBe(AgentTrustLevel.submitOnly)
    expect(manifest.observationFidelity).toBe(RuntimeObservationFidelity.none)
    expect(manifest.operations.every((o) => o.support === 'unsupported')).toBe(true)
  })

  it('requireOperation enforces capability and active state', () => {
    const active = codexEndpoint({ status: 'active' })
    const offline = codexEndpoint({ status: 'offline' })
    expect(() => requireOperation('history.read', active)).not.toThrow()
    expect(() => requireOperation('session.create', active)).not.toThrow()
    expect(() => requireOperation('session.create', offline)).toThrow(MuError)
    expect(() => requireOperation('approval.resolve', active)).toThrow(MuError)
  })

  it('endpointSupports reflects manifest declarations', () => {
    const active = codexEndpoint({ status: 'active' })
    expect(endpointSupports('history.discover', active)).toBe(true)
    expect(endpointSupports('interrupt', active)).toBe(true)
    expect(endpointSupports('interrupt', codexEndpoint({ status: 'offline' }))).toBe(false)
    expect(endpointSupports('approval.resolve', active)).toBe(false)
  })
})

describe('endpoint instance identity resolution', () => {
  it('infers Codex desktop singleton identity', () => {
    const endpoint = createRuntimeEndpoint({
      runtimeTypeID: codexRuntimeTypeID,
      displayName: 'Codex App Server',
      adapterVersion: '0.1',
      runtimeVersion: '0.1',
      location: 'local',
      provenance: 'vendor_protocol',
      permissionModel: 'fine_grained',
      capabilities: new Set(),
      status: 'active',
      guaranteeNote: 'official',
      nativeConfiguration: { 'identity.surface_kind': 'desktop_application' },
    })
    const identity = manifestFor(endpoint).instanceIdentity
    expect(identity.identityBasis).toBe('desktop_singleton')
    expect(identity.stableInstanceKey).toBe('codex:desktop')
    expect(identity.instanceLabel).toBe('Codex Desktop')
  })

  it('falls back to endpoint-based identity without terminal info', () => {
    const endpoint = createRuntimeEndpoint({
      runtimeTypeID: claudeCodeRuntimeTypeID,
      displayName: 'Claude Code CLI',
      adapterVersion: '0.1',
      runtimeVersion: '0.1',
      location: 'local',
      provenance: 'vendor_cli',
      permissionModel: 'prompt_gate',
      capabilities: new Set(),
      status: 'active',
      guaranteeNote: 'cli',
    })
    const identity = manifestFor(endpoint).instanceIdentity
    expect(identity.provider.rawValue).toBe('claude_code')
    expect(identity.surfaceKind).toBe('terminal_cli')
    expect(identity.identityBasis).toBe('endpoint_fallback')
    expect(identity.stableInstanceKey).toContain('claude_code:terminal_cli:')
    expect(identity.instanceLabel).toContain('Claude Code CLI · Mu instance')
  })
})

describe('task model sanity', () => {
  it('creates task records with defaults', () => {
    const task = createTaskRecord({
      title: 'Add tests',
      objective: 'Cover the kernel',
      successCriteria: ['tests pass'],
      constraints: [],
      pendingSteps: ['write tests'],
      repositoryPath: '/tmp/repo',
    })
    expect(task.status).toBe('ready')
    expect(task.assignedAgentIdentityID).toBeUndefined()
  })
})
