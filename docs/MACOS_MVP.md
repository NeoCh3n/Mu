# Mu macOS MVP

## Outcome

Mu is a local-first runtime control plane for moving an explicit development Project
between heterogeneous agent runtimes without pretending that hidden model context is
portable.

The first macOS release is successful when a user can:

1. register a Git-backed Project with objective, success criteria, constraints, and
   pending work;
2. capture an immutable, content-addressed Checkpoint from the current repository;
3. propose a Handoff to a capability-compatible runtime endpoint;
4. explicitly accept or reject that Handoff;
5. create a new receiving Run and mandatory Replan after a cross-runtime acceptance;
6. inspect the append-only execution ledger and artifact evidence;
7. quit and reopen the app without losing state.
8. choose a runtime-independent Agent identity for a Project;
9. use Chat, Files, Browser, Terminal snapshots, and Artifacts from the same Project
   workspace without relying on a runtime-specific desktop UI.
10. route a Workspace Chat message with `@OpenWorker` or a compatible `@Agent`,
    explicitly create or link one native session, and see that session's work in
    both Mu and OpenWorker Desktop.
11. discover prior Codex, Claude Code, and OpenWorker conversations for the exact
    canonical project folder, inspect their visible input/output separately from
    live Chat, and explicitly enable selected histories as bounded Context when
    work moves to another Agent.

## Included

- Native SwiftUI macOS application.
- Local SQLite state and append-only execution ledger.
- Runtime-neutral endpoint and capability records.
- Five runtime-independent Agent identities: Atlas, Forge, Lens, Scout, and Relay.
- Manual Agent identity and Runtime definition creation/deletion, with persistent
  deletion tombstones. Runtime removal is allowed despite Task, Run, Checkpoint, or
  Handoff references: it removes the active registry entry while preserving the
  endpoint history snapshot and every reference unchanged, and clears the Runtime
  from Agent preferred-runtime settings.
- Removed Runtimes cannot be used for new scheduling, Checkpoint capture, Handoff
  actions, or Codex actions, and tombstones prevent them from reappearing after
  restart.
- A shared task workbench with local notes and explicit `@Agent` routing in Chat,
  confined Files preview, non-persistent WebKit Browser, fixed read-only Terminal
  snapshots, and Artifacts.
- Synthetic conformance endpoints for an end-to-end offline workflow.
- Live Codex App Server discovery, capability probe, native read-only initial Task,
  and read-only Replan. Native thread/turn IDs are persisted by stage, Agent roles
  are injected into prompts, and final output is recorded in CAS and the ledger.
- OpenWorker Desktop discovery, app launch, and a probe-gated 0.1.6 legacy loopback
  adapter. The verified adapter can create or link a persistent native session,
  continue it from Workspace Chat, stream attached-turn progress, mirror native
  messages and liveness, surface explicit approval/plan/question requests, interrupt
  a turn, and reconcile artifact metadata.
- Explicit OpenWorker session selection before the first routed message leaves Mu.
  Cross-workspace links are unavailable and rejected by the Core; an older mismatched
  link can be safely detached and replaced when idle. Ambiguous delivery is never
  retried automatically.
- A provider-neutral Conversation Continuity Layer with open raw provider IDs and an
  in-process `ConversationHistoryAdapter` injection contract. Codex App Server,
  verified OpenWorker REST, and bounded read-only Claude Code JSONL are the initial
  built-in history sources. A registered additional provider can use the same
  persistence model and generic history UI without gaining live Runtime capability.
  Project folder import and **Find history** both expose provider selection and
  determinate read-only-check progress. Unselected providers are not invoked;
  discovery itself does not import or send content.
- Runtime-instance provenance that distinguishes the one Codex Desktop application
  from Codex CLI, Codex exec, VS Code, Claude Code CLI, and OpenWorker Desktop
  sessions. CLI histories stay distinct by session/source evidence; Mu explicitly
  reports when the source did not record a concrete terminal identifier.
- Dedicated imported-conversation/message tables, explicit per-Task Context source
  selection, and immutable target-specific Context receipt metadata. Reasoning,
  thinking, tools, system/developer content, and credentials are never imported.
- Exact canonical-path string matching after standardization and symlink resolution,
  without claiming device/inode physical identity.
- A 32 KiB / 80-message / 8 KiB-per-message deterministic Context bound, exact OpenWorker
  provider-instance/endpoint + native-session + canonical-workspace envelope
  exclusion, one-time injection per source revision and native binding, and no
  automatic retry after ambiguous delivery. Cross-workspace Context fails closed
  even if a live OpenWorker link was separately confirmed.
- Context plaintext staged only during dispatch, with durable persistence limited to
  hashes, IDs, byte/omission/truncation counts. Removing a local history copy clears
  unsent transient Context but cannot recall native Context already delivered.
- Git branch, commit, diff, and untracked-file evidence capture.
- Immutable Checkpoint content hashes.
- Handoff validation, accept/reject, lease-like ownership transfer, and Replan.
- Dashboard, Project workspace, Handoff inbox, runtime registry, and ledger views.

## Intentionally deferred

- Hosted relay and multi-human synchronization.
- Secrets or credential storage.
- Codex Continue, Cancel, artifact-mutating turns, workspace-chat dispatch, and
  approval responses.
- Claude Agent SDK control (not installed or exposed by Claude Desktop on this host).
- Generalized approval interception outside the verified OpenWorker adapter, review
  automation, and artifact merge.
- CAS sealing and cross-runtime transfer of general non-Git artifact bytes.
- Interactive PTY terminals.
- Authenticated attachment to current token-protected OpenWorker Desktop builds,
  credential extraction, and a live Pi adapter.
- Dynamic loading or sandboxing of third-party history adapters. The 0.7 extension
  point is a compiled, in-process injection contract.

The UI must describe synthetic and artifact-only guarantees honestly. A registered
runtime name is never presented as a working live integration without adapter
evidence.

## OpenWorker safety boundary

The 0.7 desktop compatibility adapter is activated only after a live probe verifies
OpenWorker health, Agent, and session responses. Tokenless access is restricted to
an explicit `http://127.0.0.1:<port>` URL discovered from the local OpenWorker log.
The bound session ID, workspace, Runtime endpoint, Mu Agent identity, and native Agent
name are persisted independently.

Current OpenWorker source builds launch the desktop sidecar with a private in-memory
token. Mu does not scrape the webview or process memory, guess credentials, or store a
token. A protected response fails the probe and leaves the Runtime without live
capabilities. OpenWorker approvals are never automatic: approve-once and deny are
user actions in Mu, while directory grants stay in OpenWorker Desktop.

Mu reconciles OpenWorker artifact metadata into the Artifacts surface. It does not
claim that native artifact bytes were sealed into Mu's CAS. Revealing a native path
is permitted only after workspace-confinement validation.

## Persistence

By default, data lives under:

`~/Library/Application Support/Mu/`

Tests and previews use an injected temporary directory.
