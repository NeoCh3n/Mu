# Agent workbench contract

Mu separates four concepts that vendor desktop apps often combine:

1. **Agent identity** — the Mu-owned work profile assigned to a Project and Run.
2. **Runtime endpoint** — the actual process or protocol boundary, with provenance
   and verified capabilities.
3. **Conversation history source** — reviewed, project-scoped visible input/output
   normalized by the Conversation Continuity Layer.
4. **Workspace surfaces** — stable Mu UI owned by the control plane.

The UI calls the long-lived folder-backed container a **Project**. Internal
`TaskRecord` names remain for persistence compatibility and are not the same thing
as a vendor's native task or turn.

A history source is deliberately not a Runtime endpoint. Registering a
`ConversationHistoryAdapter` can make a stable raw provider ID discoverable,
importable, and generically visible in the history UI, but it grants no Start,
Continue, streaming, approval, cancellation, or artifact capabilities. Those require
a separate Runtime adapter and probe.

## Runtime instance identity

The Agent product name is not enough to identify a source. Mu records a separate
runtime-instance identity with the product, surface, stable key, identity basis,
native session, workspace, executable/source path, and optional terminal identifier.

- One local Codex Desktop application is a desktop singleton.
- Codex `cli`, `exec`, `vscode`, and `appServer` thread sources stay distinct.
- Multiple Codex CLI and Claude Code CLI histories use their native session and
  source-file evidence rather than collapsing into one generic “Codex” or “Claude”
  source.
- A terminal or TTY name is shown as authoritative only when the Runtime or user
  supplied one. Otherwise Mu explicitly says that the terminal was not recorded and
  uses the native session as the narrowest reliable identity.

## Included identities

The 0.7.1 acceptance registry contains:

| Identity | Role | Default focus |
| --- | --- | --- |
| Atlas | Orchestrator | planning, coordination, handoff |
| Forge | Builder | implementation, files, terminal evidence |
| Lens | Reviewer | review, verification, artifacts |
| Scout | Researcher | discovery, source inspection, evidence gathering |
| Relay | Reviewer | verification, terminal evidence, handoff receipts |

These names are illustrative Mu profiles. They do not claim to be OpenWorker, Pi,
Codex, a model, or a vendor persona. A Task persists both
`assignedAgentIdentityID` and `currentEndpointID`, and every Run persists the same
two-layer boundary.

The Agents screen supports manual creation and permanent deletion. Deleting an
identity clears its assignment from current Task/Run records while retaining the
Run actor name and ledger history. A registry tombstone prevents deleted starter
profiles from being recreated on restart.

## Stable workspace surfaces

- **Chat** separates local notes from routed messages. Text without a mention stays
  local. `@OpenWorker`, or `@Agent` when the Agent resolves to the active OpenWorker
  Runtime, creates a durable queued message whose mention is removed from the native
  prompt. Unknown mentions fail visibly, and one message cannot target multiple
  native owners.
  Imported conversations are shown in a separate dashed Context panel rather than
  being presented as live Chat rows. Each source can be viewed, enabled, disabled,
  refreshed by importing again, or removed from Mu without changing the original.
  Codex, Claude Code, and OpenWorker have built-in history paths; an injected provider
  uses the same provider-neutral surface and generic label/styling.
- **Files** shows a bounded local tree and UTF-8 preview. Symlinks resolving outside
  the selected workspace are rejected.
- **Browser** uses a non-persistent `WKWebView`. A task README can be opened locally
  for offline verification; HTTP and HTTPS navigation is user initiated.
- **Terminal** exposes four fixed, read-only snapshots: `git status`,
  `git diff --stat`, recent commits, and `ls -la`. It is not an interactive shell or
  PTY.
- **Artifacts** shows immutable Checkpoints, CAS evidence references, and native
  runtime output with provenance.

The task list stays in the left split pane, the selected surface occupies the main
area, and a persistent right inspector shows objective, Agent identity, runtime,
current Run, constraints, and evidence counts.

## Workspace Chat routing

An `@Agent` name resolves through that Mu identity's preferred Runtime. A direct
`@OpenWorker` mention resolves to the registered OpenWorker endpoint and retains the
assigned or preferred Mu identity when one is available. Routing requires an active
endpoint with verified Continue and event-stream capabilities. In 0.6, OpenWorker is
the only live Runtime with a Workspace Chat continuation adapter; `@Codex` is
therefore rejected instead of being misrepresented as Continue.

The first routed message does not leave Mu immediately. The session picker requires
one explicit choice:

1. create a new native session rooted at the Mu Task workspace; or
2. link an existing OpenWorker session returned by the native session list.

Linking a session from another workspace requires a second confirmation. A native
session cannot be actively linked to two Mu Tasks, and replacing the session for the
same Task/Runtime/Agent detaches the old binding without deleting the native task.
After binding, queued messages continue the same session. A delivery whose outcome
becomes uncertain is marked ambiguous and is never retried automatically.

When the user has explicitly imported and enabled project history, the first message
to a different native binding may include one bounded Context snapshot. Mu excludes
an imported OpenWorker conversation only when its provider instance/endpoint,
native session ID, and canonical workspace exactly match the target envelope. The
snapshot is quoted as untrusted historical reference, capped at 32 KiB, 80 messages,
and 8 KiB per message. Its plaintext exists only in memory during dispatch; the
durable receipt contains only its hash, target/source and included-message IDs, byte
count, omissions, and truncations. The separately reviewed visible history remains a
local SQLite copy. Later messages on the same binding do not repeat the same source
revision.

The live session picker's separately confirmed cross-workspace link is not Context
authorization. History import and Context delivery require exact canonical-path
matches for the Task, source, and target binding and fail closed on any mismatch.
Canonical equality is string equality after standardization and symlink resolution,
not device/inode or other physical-identity equivalence.

Mu shows the bound native session ID, Agent, model, liveness, and recent activity.
WebSocket events provide live text and tool progress for the attached turn. Periodic
REST reconciliation imports native user and assistant messages, state, and artifact
metadata, including work initiated in OpenWorker Desktop. The Open button returns the
user to that same native application; Mu does not create a separate hidden transcript.

Approval remains explicit. Mu surfaces OpenWorker approve-once/deny requests, plan
approval, and questions, and can interrupt an active turn. Directory grants remain
in OpenWorker Desktop because Mu does not silently broaden filesystem access.
Artifact reconciliation records name, native path, kind, size, modification time,
endpoint, and session provenance. Reveal in Finder is allowed only when the returned
absolute path remains inside the bound workspace; this metadata mirror is not a CAS
copy of the artifact contents.

## Adapter honesty

Synthetic Runtime A and B are offline conformance fixtures. They keep deterministic
Task/Handoff testing available without vendor accounts.

The live Codex endpoint supports an initial read-only Task and a receiving read-only
Replan. Both use native `thread/start` and `turn/start`; Mu injects the assigned Agent
role, persists each native ID as its stage succeeds, and records final output in CAS
and the ledger. Mu does not expose Workspace Chat dispatch, Continue, Cancel,
workspace writes, or approval responses through that adapter.

Mu discovers the installed OpenWorker Desktop application and can open it from the
Runtime registry. The verified 0.1.6 compatibility path discovers the latest sidecar
port from the OpenWorker log, restricts tokenless access to an explicit
`http://127.0.0.1:<port>` URL, and probes protocol responses before enabling routing.
If the app is stopped, its protocol changes, or the probe fails, Mu clears live
capability claims and fails closed.

Current OpenWorker source builds inject a private launch token into the desktop
webview. Mu does not read process memory, capture that token, or offer credential
storage in 0.6. Although the transport layer understands OpenWorker's HTTP token
header and WebSocket subprotocol, the shipped desktop integration does not have a
user-authorized token provisioning path and cannot attach to that protected sidecar.
Pi remains a viable future optional adapter. Neither runtime's native
shell/browser/artifact semantics replace Mu-owned workspace surfaces.

The Conversation Continuity Layer reduces the work needed for a future Pi or other
history integration: a compiled adapter supplies a stable raw provider ID plus
bounded discovery/hydration. It does not reduce the evidence required for a future
live Pi Runtime adapter; live capability claims remain probe-gated.

The Runtime registry supports manual definitions with a stable type ID, location,
provenance, permission model, optional executable, and notes. Manual definitions
start `Offline` with no capabilities until a runtime-specific adapter probe proves
otherwise. A Runtime can be removed from the active registry even when Task, Run,
Checkpoint, or Handoff records reference it. Removal preserves the endpoint history
snapshot and all reference IDs unchanged, clears it from Agent preferred-runtime
settings, and writes a tombstone so deleted bundled definitions cannot reappear
after restart. Removed Runtimes are unavailable for new scheduling, Checkpoint
capture, Handoff actions, and Codex actions.

## Acceptance task

The app-level smoke task is:

> Use Scout through the verified OpenWorker Runtime, route a bounded message with
> `@Scout`, explicitly create or link a native session, observe the same task in
> OpenWorker Desktop, and verify mirrored output and Runtime artifact provenance in
> Mu. Then inspect the Task workspace through Files, Browser, Terminal, and
> Artifacts.

Offline acceptance remains available through the Synthetic Runtime fixture. The
automated suite additionally verifies all five identities, identity/endpoint
persistence, local-versus-routed Chat semantics, explicit OpenWorker bindings and
protocol fixtures, file confinement, terminal snapshots, Handoff accept/reject,
Checkpoint evidence, and the live Codex protocol client, including read-only initial
Task dispatch and staged native evidence.
