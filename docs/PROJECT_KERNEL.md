# Mu Project Kernel

Mu owns collaboration state; Agent runtimes own their private execution state.
Imported transcripts are optional quoted Context, never the Project database.

The first-class records are:

- `ProjectRecord`: durable Project identity, owner, folder binding, lifecycle.
- `PrincipalRecord`: accountable person or organization.
- `ProjectActorRecord`: human or Agent participant, distinct from a Runtime
  process or native session.
- `ProjectMembershipRecord`: Project role and optional Task scope.
- `DelegationRecord`: explicit permissions and restrictions granted by a
  Principal to an Agent Actor.
- `TaskProjectLink`: compatibility bridge and responsibility map for one Task.
- `TaskLeaseRecord`: exclusive, expiring ownership with heartbeat and fencing
  token. Two different Actors cannot hold one Task concurrently.
- `ProjectWorkspaceRecord`: repository, base revision, isolation strategy, and
  lifecycle. The initial adapters are read-only or externally isolated, while
  the schema is ready for Git worktrees and document versions.
- `ProjectArtifactRecord`, `ProjectReviewRecord`, and
  `ProjectApprovalRecord`: reviewable outputs and human decisions.
- `ProjectContextPackRecord`: bounded, deterministic Task contract derived from
  Mu state.
- `LedgerEvent`: append-only causal evidence with Project, Actor, Principal,
  Workspace, Artifact, Review, Approval, command, and correlation identities.

Legacy Task JSON remains decodable. Startup performs an idempotent migration:
it derives a stable Project UUID from the canonical repository path, creates the
Project Workspace and responsibility link, and preserves all existing Task,
Run, Chat, Handoff, and history records.

## Core invariants

1. One active Task Lease at a time. Expired leases receive a new fencing token.
2. A lease requires an active Actor, Principal, Membership, and task-scoped
   Delegation.
3. Runtime output is submitted as a Project Artifact; completion is not the
   same as human acceptance.
4. Runtime approvals are linked to Mu Project Approval records.
5. Project removal archives only Mu's catalog entry. It never deletes the
   folder or another Agent's history.
6. Context Packs contain the objective, constraints, permissions, acceptance
   tests, expected outputs, accepted Artifact references, dependencies, and
   base revision. Selected old conversations are appended only as bounded,
   explicitly untrusted quoted context.

