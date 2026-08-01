# Mu multi-Agent Context architecture audit

Date: 2026-07-29

## Conclusion

Mu already has two useful but separate foundations:

1. a Project Kernel for accountable Project collaboration; and
2. a Conversation Continuity Layer that imports bounded visible history and
   creates one-time delivery receipts.

It does **not** yet have the full Context Kernel required for multiple Agents.
In particular, enabled transcripts are currently selected into one quoted text
envelope. That is safer than treating them as instructions, but it still loses
the candidate/canonical boundary and cannot represent conflicts, authority,
sensitivity, or a permission-filtered set of Project facts.

The smallest correct upgrade is to retain imported conversations as auditable
raw sources, normalize explicitly shared claims into Project-scoped Context
Records, require controlled acceptance before they become canonical, preserve
conflicts, and generate an immutable Task-specific Context Pack for every
Runtime session.

## Existing implementation and reuse decision

| Target | Existing implementation | Responsibility today | Gap | Decision |
| --- | --- | --- | --- | --- |
| Project | `Sources/MuCore/ProjectKernel.swift` (`ProjectRecord`) | Stable folder-backed Project identity | None for Context ownership | Reuse |
| Principal | `ProjectKernel.swift` (`PrincipalRecord`) | Accountable person/organization | Context actions do not yet reference it | Reuse and reference |
| Actor / Agent | `ProjectActorRecord`, `AgentIdentity` | Durable participant separate from Runtime | No Context author/reviewer policy | Reuse and authorize |
| Membership | `ProjectMembershipRecord` | Project and optional Task scope | Not applied before Context retrieval | Reuse as first filter |
| Delegation | `DelegationRecord` / `ProjectPermission` | Explicit Agent authority | No Context-specific permissions | Extend permissions |
| Task | `TaskRecord` + `TaskProjectLink` | Objective, constraints, responsibility | No explicit Context Record references | Extend link compatibly |
| Runtime session | `Sources/MuCore/Models.swift` (`RuntimeSessionBinding`) | Project, Workspace, Actor, Principal, Lease and native session identity | No immutable Context Pack ID | Extend with optional Pack receipt |
| Workspace | `ProjectWorkspaceRecord` | Exact repository/worktree and base revision | No Context selection change needed | Reuse |
| Event log | `LedgerEvent`, SQLite `ledger` | Append-only causal evidence | Context operations are not logged | Reuse for every transition/query |
| Artifact | `ProjectArtifactRecord` | Reviewable CAS/native output | Artifact acceptance is the only canonical input today | Reuse as Pack input |
| Review / Approval | `ProjectReviewRecord`, `ProjectApprovalRecord` | Human review and Runtime permission decisions | No Context acceptance link | Reuse actor rules; add Context transitions |
| Raw history | `Sources/MuCore/ConversationHistory.swift` (`ImportedConversation`, `ImportedConversationMessage`) | Provider/instance/session/workspace provenance and visible-only local copy | Task-scoped, no source Actor/Principal/retention policy | Keep as raw source; bridge to `ContextSourceRecord` |
| History selection | `TaskContextSource` | Per-conversation enable switch | Directly selects transcript text | Retain for legacy review, stop treating it as Project truth |
| Delivery receipt | `ContextSnapshot` | Target binding, selected messages, hash/counts; generated plaintext redacted | No Project/Actor/policy/Pack record references | Retain as legacy transcript receipt |
| Imported pack | `ContextPackBuilder` | Bounded quoted history: 32 KiB / 80 messages / 8 KiB each | Combines several Agent transcripts into one text envelope | Replace in live dispatch with Context Records |
| Project pack | `ProjectContextPackRecord` | Immutable Task objective, permissions, revision and accepted Artifact IDs | No Context Records, conflicts, selection policy, runtime/actor or token budget | Extend compatibly |
| Persistence | `Sources/MuCore/SQLiteStore.swift` | WAL SQLite, JSON records, transactions, immutable insert helper, dedicated history tables | No indexed Project-scoped Context tables or DB idempotency constraints | Add dedicated Context tables |
| Runtime adapters | Codex App Server, Claude Code CLI, OpenWorker sidecar | Inject Project pack plus optional history envelope | Pack–session relation is only an event payload; OpenWorker is asymmetric | Bind all three to the same immutable Pack |
| Authorization | Project Kernel checks Actor/Principal/Membership/Delegation for Lease | Context selection only checks Task and exact workspace | Sensitive content could be read before policy filtering | Authorize before retrieval, relevance, summary, or budget |
| MCP / retrieval | None | — | No `context.search` / `context.get_record` | Add safe local service contract first; MCP transport remains an adapter |
| Agent memory | None in Mu | Runtime-private | No problem if kept private | Do not import automatically |

## Existing safety properties to preserve

- Built-in history readers exclude reasoning, thinking, tool and system content.
- Canonical workspace comparison is exact after standardization and symlink
  resolution.
- Imported messages preserve provider instance, native session, item identity,
  ordinal, revision fingerprint, and content hash.
- Generated transcript Context plaintext is redacted after dispatch; durable
  snapshots contain references, hashes, and counts.
- `ProjectContextPackRecord` already uses immutable insertion.
- Runtime identity, Agent identity, Principal, Actor, Workspace, and Lease are
  separate records.

## Required Context Kernel

The first implementation adds these Project-scoped records:

- `ContextSourceRecord`: source type, Actor, Principal, Runtime/session,
  checksum, original time, CAS/raw reference, lifecycle.
- `ContextRecord`: normalized fact/requirement/decision/constraint/assumption/
  finding/artifact reference/task state; candidate/accepted/disputed/
  superseded/rejected status; authority, scope, sensitivity, checksum and
  source.
- `ContextRelationRecord`: supports, contradicts, supersedes, derived-from,
  depends-on, implements, reviews, references.
- `ContextConflictRecord`: all competing Records, deterministic conflict type,
  unresolved/resolved/accepted-multiple state and resolution receipt.
- `ContextAccessPolicyRecord`: namespace, visibility, sensitivity, Actor,
  Principal and Task scope.
- `ContextImportJobRecord`: idempotency, validation/progress and terminal
  result.
- immutable `ProjectContextPackRecord` extensions and Pack item references.

## State and authority rules

1. Every Source and Record belongs to exactly one Project.
2. Every Record references an existing Source in the same Project.
3. Agent/imported records begin as `candidate`; an Agent cannot create
   `accepted` or `project_approved` state.
4. Payload and source are immutable. Controlled status transitions are the only
   updates.
5. Supersession creates a new Record and relation; the old Record remains.
6. Conflicting Records never overwrite each other.
7. Canonical Project Context is a query: accepted, not superseded, readable by
   the current Actor.
8. Permission filtering runs before relevance selection, compaction, caching,
   or token budgeting.
9. Packs are immutable and save policy version, Context revision, Record,
   Artifact, Conflict and Source references, runtime/actor identity, base
   revision, rendered CAS hash and generation time.
10. Every Runtime binding records the exact Pack it received.

## Deterministic v1 policies

- No vector database or LLM conflict resolver.
- Conflict detection uses same normalized subject, overlapping scope and valid
  time, and a different canonical payload hash.
- Selection order is Task objective/acceptance criteria, explicit Task scope,
  accepted requirements, constraints, decisions, dependency artifacts,
  unresolved relevant conflicts, then other accepted facts.
- Project and Task scopes are exact IDs. Restricted/secret Records require an
  explicit access policy; external secret-like input is rejected before raw
  persistence.
- Search v1 is deterministic normalized substring matching on readable Record
  subject and rendered content.

## File-level implementation plan

1. Add `Sources/MuCore/ContextKernel.swift` for domain records, bundle schema,
   state machines, secret scanner and deterministic canonical encoding.
2. Add dedicated indexed tables and CRUD methods to
   `Sources/MuCore/SQLiteStore.swift`; every fetch requires `projectID`.
3. Add `Sources/MuCore/ControlPlaneService+ContextKernel.swift` for import,
   transitions, conflict resolution, authorization, pack building and search.
4. Extend `ProjectContextPackRecord`, `RuntimeSessionBinding`,
   `TaskProjectLink`, and `ProjectPermission` only with optional/default-decoded
   compatibility fields.
5. Replace live Runtime transcript concatenation with one common prepared
   Context Pack path for Codex, Claude Code and OpenWorker. Imported
   conversations remain reviewable raw Sources and are never automatically
   canonical.
6. Add a Context surface to the Project workspace for Sources, Candidate and
   Canonical Records, Conflicts and Pack receipts.
7. Add service-level `context.search` and `context.get_record` contracts with
   session/Actor authorization and ledger receipts. A future MCP server can
   expose the same methods without becoming the authority layer.

## Acceptance

The implementation is complete only when tests prove:

- importing one bundle twice is idempotent;
- every Record is traceable to Agent/Principal/Runtime session and Source;
- Agent A private/restricted Context is unavailable to Agent B;
- Project A Context cannot be queried or packed for Project B;
- an Agent cannot accept canonical Context;
- conflicting values remain side-by-side until explicit resolution;
- supersession preserves the previous Record;
- the same versioned input rebuilds the same Pack item set and hash;
- token budget and sensitivity filtering happen before rendering;
- Codex, Claude Code and OpenWorker bindings persist the exact Pack ID;
- a historical Runtime delivery can be reconstructed from Pack and item
  references.
