# Mu Context Kernel

Mu does not merge Codex, Claude Code, OpenWorker, or future Agent histories
into one transcript. It preserves their provenance and promotes only reviewed,
normalized records into Project Context.

## Context layers

1. **Raw Source** — immutable provenance for an Agent export, Runtime
   session, repository, Artifact, external source, or human input. Large bytes
   live in local CAS; a Source stores only its receipt and policy.
2. **Candidate Record** — a normalized claim proposed by an Agent or human.
   Candidate, disputed, and rejected records are never Project truth.
3. **Accepted Record** — an explicitly human-reviewed canonical projection.
4. **Derived state** — relations, conflicts, and supersession receipts.
5. **Ephemeral delivery** — an Actor-specific, Task-specific immutable
   Context Pack for exactly one Runtime binding and fenced Task lease.

`Runtime Context != Project Context` and `Agent Memory != Project Truth`.
Imported transcripts remain Raw Sources. They are never copied directly into a
Runtime prompt.

## Kernel records

- `ContextSourceRecord`
- `ContextRecord`
- `ContextRelationRecord`
- `ContextConflictRecord`
- `ContextAccessPolicyRecord`
- `ContextImportJobRecord`
- `ProjectContextPackRecord`
- `ContextPackItemRecord`
- `ContextTransitionRecord`
- `ContextDeliveryReceipt`

All records are Project-scoped. SQLite uses composite Project foreign keys for
Context relationships. Payload and provenance fields are immutable; lifecycle
updates use compare-and-swap revisions plus append-only transition receipts.

## Import boundary

`importAgentContextBundle` accepts a versioned, provider-neutral bundle.

Before any bytes enter SQLite, CAS, or Ledger, Mu verifies:

- UTF-8, JSON grammar, nesting depth, size, and numeric validity;
- duplicate and escape-equivalent JSON keys;
- schema version, field sizes, record count, and record size;
- forbidden secrets and private-reasoning field names;
- claimed Project, Principal, provider, and Task scopes against the
  authenticated Mu Actor;
- exact Actor-scoped idempotency key and bundle checksum.

Bundle identity fields are untrusted metadata. Mu derives authority from the
authenticated Actor. Imported records start as restricted, owner-only Agent
claims. V1 rejects Artifact references because the bundle cannot prove their
bytes and CAS hash.

## Review and conflict model

Agents may propose or dispute Context. They cannot accept, reject, supersede,
or resolve canonical state.

Human review supports:

- candidate/disputed → accepted;
- candidate/disputed → rejected;
- candidate/accepted → disputed;
- accepted/disputed → superseded by an already accepted, readable record;
- unresolved conflict → one accepted member or explicitly accepted multiple
  members.

Supersession does not rewrite either claim. It adds an immutable
`supersedes` relation and a lifecycle receipt. SQLite rejects supersession
cycles.

Conflict detection is deterministic for overlapping records with the same
normalized subject and different value receipts. Mu does not use an LLM to
resolve conflicts.

## Permission-first retrieval

Content is never loaded before authorization. Mu first reads metadata-only
Source and Record headers, then evaluates:

- active Project, Actor, Principal, and Membership;
- human role or Agent delegation;
- Task scope;
- current Source and Record policy versions;
- visibility and allowlists;
- effective sensitivity.

Only authorized IDs are used to load and search payloads. Conflict and relation
views are projected to visible members, so hidden IDs and counts are not
revealed.

## Governed Context Pack

Every outbound Runtime turn builds a new immutable Pack pinned to:

- Project, Task, Workspace, Actor, and Principal;
- Runtime endpoint and binding;
- active Task lease and fencing token;
- selection, canonicalization, and budget estimator versions;
- Task, Context-input, and policy revisions;
- exact selected Record, Conflict, and Artifact versions;
- current Source, Record, Artifact, and Pack policy receipts;
- rendered content hash and local CAS URI.

Policy filtering happens before ranking, rendering, summarization, or budget
selection. Accepted records are rendered as quoted evidence and explicitly
marked as data rather than instructions. An unresolved conflict is selected
atomically with all visible members or omitted entirely.

Freshness validation recomputes revisions from all currently authorized
accepted inputs, not only the items selected by the old Pack. Therefore a new
accepted record, policy change, conflict resolution, Task contract change, or
missing CAS object invalidates the old Pack before dispatch.

Each Runtime turn records:

1. `prepared` immediately before external submission;
2. `delivered` after the native Runtime returns a thread/turn/session receipt;
   or
3. `failed` if submission does not establish native delivery.

Binding, Run, Pack, Lease, Actor, Principal, Endpoint, Workspace, revisions,
and hashes must match exactly. SQLite permits one prepared receipt and only
one terminal receipt for a Runtime turn.

## Runtime integration

Codex App Server, Claude Code CLI, and OpenWorker Desktop use the same Pack and
delivery contract. Provider adapters own only native transport:

- Codex: official App Server thread/turn;
- Claude Code: managed CLI session/stream-json process;
- OpenWorker: verified local session protocol.

Legacy imported-history envelopes are deprecated and are not used by any live
dispatch path.

## Runtime Context Gateway

Mu exposes provider-neutral service operations:

- `context.search`
- `context.get_record`

A Runtime supplies only its opaque Mu binding ID and query parameters. Mu
derives Project, Task, Actor, Principal, Run, Endpoint, Workspace, Lease, and
Pack from persisted state. Calls require a working binding, active Run,
governed Pack, exact fenced lease, valid CAS/item receipts, and a delivered
native adapter receipt. Normal Context policies are evaluated again for every
result.

This is the service boundary for a future local MCP server or remote API. MCP
is a transport option, not the source of Context truth or authorization.

## Legacy history migration

Existing `ImportedConversation` rows are idempotently projected into
restricted, owner-only, Task-scoped Raw Source metadata. Migration creates no
Context Records. Selecting history makes it eligible for future bounded
candidate extraction and human review; it does not inject the transcript.

Removing a local imported transcript marks its Raw Source redacted while
retaining immutable audit and delivery hash receipts.

## Adapter extension contract

A future Agent adapter should provide:

1. a stable Runtime instance identity;
2. history discovery/read support as a separate, optional facet;
3. a strict Agent Context Bundle exporter for normalized proposals;
4. live session submit/observe/interrupt capabilities as supported;
5. native delivery receipt material;
6. no self-asserted Project, Principal, or authorization decisions.

The Context Kernel and Runtime Gateway remain provider-neutral. A new adapter
does not need a new Project truth model.
