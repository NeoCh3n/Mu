import { describe, expect, it } from 'vitest'
import { uuid } from '../src/identity.ts'
import {
  createDelegationRecord,
  createProjectArtifactRecord,
  createProjectContextPackRecord,
  createProjectMembershipRecord,
  createProjectWorkspaceRecord,
  createTaskLeaseRecord,
  delegationIsActive,
  membershipIsActive,
  ProjectPermission,
  renderedContextPackMarkdown,
  stableAgentIdentityActorID,
  stableDelegationID,
  stableMembershipID,
  stableRuntimeActorID,
  stableWorkspaceID,
  taskLeaseIsActive,
} from '../src/project-kernel/index.ts'

const A = uuid('a1b2c3d4-e5f6-4789-abcd-ef0123456789')
const B = uuid('9f8e7d6c-5b4a-4321-8f0e-dcba98765432')
const C = uuid('01234567-89ab-4cde-8f01-23456789abcd')

describe('stable IDs', () => {
  it('runtime actor and agent-identity actor IDs are deterministic and distinct', () => {
    const a1 = stableRuntimeActorID(A)
    const a2 = stableRuntimeActorID(A)
    const b1 = stableRuntimeActorID(B)
    expect(a1).toBe(a2)
    expect(a1).not.toBe(b1)
    expect(stableAgentIdentityActorID(A)).not.toBe(a1)
    expect(a1[14]).toBe('5')
  })

  it('membership, delegation, workspace IDs are stable', () => {
    expect(stableMembershipID(A, B)).toBe(stableMembershipID(A, B))
    expect(stableDelegationID(A, B, C)).not.toBe(stableDelegationID(A, B, undefined))
    expect(stableWorkspaceID(C)).toBe(stableWorkspaceID(C))
  })
})

describe('membership lifecycle', () => {
  it('is active when status is active and not expired', () => {
    const future = new Date(Date.now() + 60_000)
    const m = createProjectMembershipRecord({
      projectID: A,
      actorID: B,
      role: 'contributor',
      expiresAt: future,
    })
    expect(membershipIsActive(m)).toBe(true)
  })

  it('is inactive when expired or suspended', () => {
    const past = new Date(Date.now() - 60_000)
    expect(
      membershipIsActive(
        createProjectMembershipRecord({ projectID: A, actorID: B, role: 'owner', expiresAt: past }),
      ),
    ).toBe(false)
    expect(
      membershipIsActive(
        createProjectMembershipRecord({ projectID: A, actorID: B, role: 'owner', status: 'suspended' }),
      ),
    ).toBe(false)
  })
})

describe('task lease fencing', () => {
  it('is active within its window', () => {
    const lease = createTaskLeaseRecord({
      projectID: A,
      taskID: C,
      agentActorID: B,
      endpointID: A,
      fencingToken: 7,
      expiresAt: new Date(Date.now() + 60_000),
    })
    expect(lease.fencingToken).toBe(7)
    expect(taskLeaseIsActive(lease)).toBe(true)
  })

  it('is inactive when expired or released', () => {
    const expired = createTaskLeaseRecord({
      projectID: A,
      taskID: C,
      agentActorID: B,
      endpointID: A,
      fencingToken: 1,
      expiresAt: new Date(Date.now() - 60_000),
    })
    expect(taskLeaseIsActive(expired)).toBe(false)
    const released = createTaskLeaseRecord({
      projectID: A,
      taskID: C,
      agentActorID: B,
      endpointID: A,
      fencingToken: 2,
      expiresAt: new Date(Date.now() + 60_000),
      state: 'released',
      releasedAt: new Date(),
    })
    expect(taskLeaseIsActive(released)).toBe(false)
  })
})

describe('delegation', () => {
  it('is active when status active and unexpired', () => {
    const d = createDelegationRecord({
      projectID: A,
      principalID: A,
      delegatedByActorID: A,
      agentActorID: B,
      permissions: [ProjectPermission.readProjectState, ProjectPermission.readContext],
      expiresAt: new Date(Date.now() + 60_000),
    })
    expect(delegationIsActive(d)).toBe(true)
    expect(d.permissions.has('project.read')).toBe(true)
    expect(d.permissions.has('context.manage')).toBe(false)
  })

  it('defaults to project-scoped delegation when no task is given', () => {
    const d = createDelegationRecord({
      projectID: A,
      principalID: A,
      delegatedByActorID: A,
      agentActorID: B,
      permissions: [],
    })
    expect(d.taskID).toBeUndefined()
    expect(delegationIsActive(d)).toBe(true)
  })
})

describe('workspace', () => {
  it('canonicalizes repository paths', () => {
    const w = createProjectWorkspaceRecord({
      projectID: A,
      taskID: C,
      repositoryPath: '/Users/neo/Desktop/Mu',
      isolationKind: 'shared_project_folder',
    })
    expect(w.repositoryPath).toBe('/Users/neo/Desktop/Mu')
    expect(w.id).toBe(w.id)
  })
})

describe('project artifacts', () => {
  it('defaults version and status', () => {
    const a = createProjectArtifactRecord({
      projectID: A,
      taskID: C,
      producerActorID: B,
      kind: 'patch',
      title: 'fix-typo',
      uri: 'local-cas://sha256/abc',
      sha256: 'abc',
    })
    expect(a.version).toBe(1)
    expect(a.status).toBe('submitted')
    expect(a.sourceArtifactIDs).toEqual([])
  })
})

describe('renderedContextPackMarkdown', () => {
  it('matches the Swift markdown layout', () => {
    const pack = createProjectContextPackRecord({
      projectID: A,
      taskID: B,
      workspaceID: C,
      objective: 'Implement the widget',
      relevantFilePaths: ['src/widget.ts', 'tests/widget.test.ts'],
      constraints: ['No new dependencies'],
      permissions: ['project.read', 'repository.read'],
      acceptanceTests: ['widget renders'],
      expectedOutputs: ['a working widget'],
      baseRevision: 'abc123',
      acceptedArtifactIDs: [C],
      dependencyTaskIDs: [A],
      renderedContextMarkdown: '## Fact\naccepted',
      contentSHA256: 'x'.repeat(64),
    })
    const md = renderedContextPackMarkdown(pack)
    expect(md).toContain('# Mu Project Context Pack')
    expect(md).toContain(`Task: ${B}`)
    expect(md).toContain('## Objective\nImplement the widget')
    expect(md).toContain('## Relevant files\n- src/widget.ts\n- tests/widget.test.ts')
    expect(md).toContain('## Permissions\n- project.read\n- repository.read')
    expect(md).toContain('## Base revision\nabc123')
    expect(md).toContain('## Governed Project Context\n## Fact\naccepted')
    // Ordering: objective first, governed context last.
    expect(md.indexOf('## Objective')).toBeLessThan(md.indexOf('## Governed Project Context'))
  })

  it('omits empty sections', () => {
    const pack = createProjectContextPackRecord({
      projectID: A,
      taskID: B,
      workspaceID: C,
      objective: 'x',
      contentSHA256: 'y'.repeat(64),
    })
    const md = renderedContextPackMarkdown(pack)
    expect(md).not.toContain('## Relevant files')
    expect(md).not.toContain('## Base revision')
    expect(md).not.toContain('## Dependencies')
  })
})

describe('uuid validation', () => {
  it('normalizes to lowercase and rejects invalid input', () => {
    expect(uuid('A1B2C3D4-E5F6-4789-ABCD-EF0123456789')).toBe(
      'a1b2c3d4-e5f6-4789-abcd-ef0123456789',
    )
    expect(() => uuid('not-a-uuid')).toThrow(TypeError)
  })
})
