# Mu

Mu is a local-first runtime control plane for explicit, verifiable project Handoffs
between heterogeneous agent runtimes.

The macOS app is a native SwiftUI application backed by SQLite and a local
content-addressed evidence store. It implements Projects, Runs, immutable Git
Checkpoints, receiver-approved Handoffs, mandatory cross-runtime Replan, capability
gating, and an append-only execution ledger.

Mu 0.7.1 provides runtime-independent Agent identities and a shared macOS Project
workbench. Every Project exposes Chat, Files, Browser, Terminal snapshots, and
Artifacts regardless of the selected runtime. Atlas, Forge, Lens, Scout, and Relay
are illustrative Mu work profiles; the actual runtime endpoint and provenance stay
visible beside the identity.

The macOS UI calls the long-lived folder-backed container a **Project**. Existing
persistence and adapter contracts retain the internal `TaskRecord` name for backward
compatibility; a native Agent may still call one execution unit a task or turn.

Workspace Chat now has an explicit routing rule. Text without a mention remains a
local note. `@OpenWorker`, or `@Agent` when that Agent's preferred Runtime is the
verified OpenWorker endpoint, queues the message for a persistent native session.
On the first routed message, Mu requires the user to link an existing OpenWorker
session or create a new one before sending anything. Later messages continue that
same binding. A linked session remains visible in OpenWorker Desktop while Mu mirrors
native messages, live progress, approval requests, and artifact metadata.

Mu 0.7 adds a project-scoped **Conversation Continuity Layer**. Its provider-neutral
conversation, message, provenance, revision, selection, and Context-receipt records
let a Project retain reviewed history while the user changes Agent or Runtime. The
initial built-in sources are Codex, Claude Code, and OpenWorker. `ConversationProvider`
is an open raw string identifier rather than a closed provider enum, and
`ConversationHistoryAdapter` is the injection contract for a compiled integration to
discover and hydrate another provider without adding provider-specific fields to
Mu's persistence model. A registered unknown provider can be imported and receives
a generic history UI label and treatment; this history extension point does not by
itself add live Runtime control.

Creating a Project starts with importing its folder. The user chooses which
registered history providers Mu may inspect, and the Project opens with a determinate,
real-time read-only-check progress view. The same provider selector is available from
Workspace Chat through **Find history**. Mu only invokes selected providers, then
shows conversations whose canonical workspace exactly matches the Project folder in a
visually separate review surface. The user explicitly chooses which local copies may
become Context. Codex history
comes from the official App Server, OpenWorker history from the verified local REST
protocol, and Claude Code history from a bounded read-only `history_only` path. Only
visible user/assistant text is copied by the built-in adapters; reasoning, thinking,
tools, system messages, and developer instructions are excluded.

The first eligible message to a different native OpenWorker session carries one
quoted, untrusted Context snapshot capped at 32 KiB, 80 messages, and 8 KiB per
message. Mu records the source revisions, included message IDs, SHA-256, byte count,
omissions, and truncations, but not the generated Context plaintext. That full
envelope exists only in memory for dispatch; the durable snapshot receipt and ledger
contain only hashes, IDs, and counts. Imported visible history is still an explicit
local SQLite copy. Mu excludes an imported OpenWorker source only when its provider
instance, native session, and canonical workspace match the target envelope, fails
closed before sending Context across workspaces, and does not resend an ambiguous
delivery automatically. A newly linked OpenWorker session must match the Task's
exact canonical workspace. Older mismatched links are diagnosed before dispatch and
can be safely replaced with an exact-workspace session while queued messages remain
queued.

Canonical workspace matching means exact string equality after path standardization
and symlink resolution. It is deliberately not a claim of filesystem physical
identity: beyond resolving symlinks, Mu does not use device/inode identity to merge
different resulting paths or worktrees. Claude Code's bounded local history scan
starts only when the user selects Claude Code while creating a Task or using
**Find history**; discovery
alone neither imports nor sends content. Removing Mu's local history copy also
clears any unsent transient Context derived from it, but cannot recall Context
already delivered to a native Runtime.

Mu 0.7.1 also keeps the Agent product separate from the concrete instance that
created a conversation. Codex history preserves native `appServer`, `cli`, `exec`,
and `vscode` sources. The one local Codex desktop application is shown as
**Codex Desktop**; multiple Codex CLI and Claude Code CLI histories remain distinct
by native session and source-file identity. If vendor history does not record a TTY
or terminal name, Mu says so instead of inventing one. Runtime registration can
carry an explicit terminal identifier when an adapter or user supplies it.

Agent identities can be added or deleted, while Runtime definitions can be added or
removed from the active registry.
Removing a Runtime removes it from the active registry even when Project, Run,
Checkpoint, or Handoff records reference it. Mu preserves the endpoint history
snapshot and every reference unchanged, clears it from Agent preferred-runtime
settings, and writes a tombstone so it cannot reappear after restart. A removed
Runtime cannot be used for new scheduling, Checkpoint capture, Handoff actions, or
Codex actions.

Mu also includes a live Codex App Server adapter. The app negotiates the official
stdio protocol, probes account/thread capabilities, and can dispatch an initial Project run
or a receiving Replan through `thread/start` and `turn/start`. Both paths run inside
a read-only sandbox with approval escalation disabled. The selected Mu Agent role is
included in the prompt. Native Codex thread and turn IDs are persisted as soon as
each protocol stage succeeds, and the final output is stored in the
content-addressed evidence store and append-only ledger. Mu 0.7 does not claim
Codex Continue, Cancel, workspace writes, Workspace Chat dispatch, or approval
responses.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Xcode 26.6 is the verified build toolchain)

## Build the macOS app

```sh
./scripts/build-macos.sh
```

The signed local bundle is written to:

```text
build/Mu.app
```

Open `Package.swift` in Xcode for development, or run the `MuApp` Swift Package
scheme.

## Test

```sh
./scripts/test.sh
```

The tests exercise deterministic Checkpoint hashing, Agent and Runtime registry CRUD,
deletion tombstones and reference preservation, task/Run identity binding, routed and
local Workspace Chat, explicit native-session binding, OpenWorker protocol fixtures
and failure semantics, confined file preview, read-only terminal snapshots, dirty Git
evidence capture, a complete cross-runtime Handoff/Replan, rejection ownership
semantics, Codex protocol negotiation, staged native ID persistence, CAS/ledger
evidence, and the native read-only Codex Project/Replan event stream. Conversation
continuity coverage verifies Codex/Claude filtering, canonical workspace matching,
idempotent import, same-text/different-ordinal preservation, deterministic Unicode
Context bounds, target-aware one-time delivery, injected unknown-provider history
import, and history survival after Runtime removal.

## Current integration boundary

Mu ships two offline synthetic endpoints so the control-plane workflow remains
testable without vendor accounts. The manual artifact bridge captures Git evidence
but does not claim live runtime control. A live Codex App Server endpoint is
auto-discovered from the installed ChatGPT/Codex app and must pass an in-app probe
before scheduling. Claude Desktop exposes no supported local agent-control CLI on
this machine, so Mu keeps that boundary artifact-only instead of claiming control.
Mu discovers and can open the installed OpenWorker Desktop application. For the
verified 0.1.6 build, an explicit probe may activate its tokenless legacy sidecar only
when it is running on `http://127.0.0.1:<port>`. The probe checks health, Agent, and
session responses before advertising Start, Continue, streaming, approval-intent,
Cancel, and artifact-discovery capabilities. Probe failure clears those claims.

Current OpenWorker source builds protect the desktop sidecar with a private,
in-memory launch token. Mu 0.7 does not extract that token, scrape the embedded
webview, or persist OpenWorker credentials, so those builds remain unavailable
unless a future explicit authenticated-endpoint flow is added. Pi remains a
researched future adapter candidate and is not presented as live in this build.
Adding Pi or another provider to the Conversation Continuity Layer would enable
reviewed history import only; live Start, Continue, events, approvals, and artifacts
would still require a separate capability-probed Runtime adapter.

Workspace Chat renders imported, native, and local messages as Markdown. OpenWorker
streaming batches deltas, treats the native final message as authoritative, ignores
late deltas, and avoids no-change polling reloads so completed replies stop
immediately and the macOS interface remains responsive.

See [docs/MACOS_MVP.md](docs/MACOS_MVP.md) for scope and acceptance criteria.
See [docs/AGENT_WORKBENCH.md](docs/AGENT_WORKBENCH.md) for identity and surface
boundaries.
See [docs/CODEX_ADAPTER.md](docs/CODEX_ADAPTER.md) for the live adapter contract.
See [docs/OPENWORKER_ADAPTER.md](docs/OPENWORKER_ADAPTER.md) for native-session
routing and synchronization guarantees.
See [docs/HISTORY_CONTEXT.md](docs/HISTORY_CONTEXT.md) for the Conversation
Continuity Layer, provider extension contract, resource bounds, filtering, consent,
persistence, and cross-Agent Context guarantees.
See [docs/SECOND_RUNTIME_PROBE.md](docs/SECOND_RUNTIME_PROBE.md) for the honest
Claude, OpenWorker, and second-runtime boundary.
