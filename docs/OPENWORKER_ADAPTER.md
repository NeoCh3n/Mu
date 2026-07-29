# OpenWorker adapter contract

Mu 0.7 integrates with an OpenWorker native session rather than imitating an
OpenWorker transcript. The session ID is persisted with the Mu Task, Run, Runtime
endpoint, Agent identity, native Agent, model, and workspace so that both applications
refer to the same unit of work.

## Activation

The Runtime registry first discovers `/Applications/OpenWorker.app` and exposes only
Open app and Probe. Discovery alone does not enable dispatch.

For the verified OpenWorker Desktop 0.1.6 compatibility path, Mu finds the most
recent Uvicorn listener in OpenWorker's local server log. The endpoint must be an
explicit `http://127.0.0.1:<port>` URL. Mu then probes:

- `GET /v1/health`;
- `GET /v1/agents`; and
- `GET /v1/sessions`.

Only compatible `ok` responses activate the advertised Start, Continue, Replan,
Cancel, event-stream, approval-intent, Git/artifact-discovery, and Checkpoint-evidence
capabilities. Stopping OpenWorker, changing the protocol, returning an incompatible
schema, or requiring an unavailable token causes the adapter to fail closed.

## Mention and session lifecycle

Workspace Chat applies these rules:

1. No mention means an append-only local note. No Runtime receives it.
2. `@OpenWorker` resolves directly to the active OpenWorker endpoint.
3. `@Agent` resolves through that Mu Agent's preferred endpoint. It routes only when
   that endpoint exposes verified Workspace Chat continuation; in 0.6 that live
   adapter is OpenWorker.
4. Unknown mentions or multiple distinct targets are rejected visibly.
5. Mu removes the routing mention and surrounding separator punctuation from the
   native prompt.

If no compatible binding exists, Mu persists the message as Awaiting session and
shows a picker. Nothing is sent until the user chooses:

- **Create** — prepare a new `mu-…` native session rooted at the Mu Task's workspace;
  or
- **Link** — select an existing session returned by OpenWorker.

A different-workspace link requires confirmation. Mu rejects a native session that
is already actively linked to another Mu Task. Replacing a binding for the same
Task/Runtime/Agent marks the old binding Detached but does not delete the OpenWorker
session.

After binding, messages are queued and delivered serially over:

`/ws/session/{session_id}?workspace=<absolute-path>&agent=<agent>`

Mu waits for a matching `ready` acknowledgement before sending a `user_message`.
`turn_start` confirms delivery. If the connection is lost after send but before that
acknowledgement, Mu marks delivery Ambiguous and does not retry automatically.

## Imported history and Context

OpenWorker history discovery and import require the session workspace to exactly
match the Task's canonical path. Canonical equality means string equality after path
standardization and symlink resolution; it is not device/inode or other physical
identity. A session that moved, reports another workspace, or no longer appears in
the latest discovery result is rejected.

For Context delivery, Mu compares the exact source/target provenance envelope:
OpenWorker provider instance/endpoint, native session ID, and canonical workspace.
An imported source matching that envelope is excluded, preventing Mu from feeding
the session's own transcript back into itself. All enabled sources and the target
binding must also match the Task's canonical workspace. The live picker disables
sessions from another folder, and the Core rejects an attempted cross-workspace bind
even if another caller bypasses the UI. For a mismatched binding created by an older
Mu build, the Workspace banner diagnoses the relink requirement before dispatch.
When the native session is idle, Mu can safely detach it, preserve completed history,
return queued messages to `awaitingSession`, and create an exact-workspace
replacement.

The bounded Context plaintext is staged only while dispatching the native message.
Mu then redacts it from the local Chat row and durably retains only a receipt with
hash, target/source and included-message IDs, byte count, omissions, and
truncations. Removing Mu's imported local copy clears any unsent transient Context
derived from it, but cannot recall an envelope already delivered to OpenWorker.

OpenWorker is the initial provider that has both sides of Mu's separation: the
Conversation Continuity Layer identifies its history as `openworker`, while this
document's capability-probed Runtime adapter controls and mirrors the native
session. Either side may fail or be unavailable independently; history metadata
alone never activates live routing.

## Bidirectional mirror

For an attached session, Mu consumes native WebSocket events for:

- assistant text deltas and completed messages;
- turn and tool progress;
- permission, directory, plan, and question requests;
- interruption, errors, input rejection, and `turn_done`.

Mu also reconciles the session over REST every five seconds and after a turn. A
no-change poll does not reload or republish the UI. Reconciliation imports user and
assistant messages without duplicating already-delivered Mu
messages, updates native liveness and attention state, and discovers artifact
metadata. Messages created in OpenWorker Desktop therefore appear in Mu after
reconciliation, and a message sent from Mu is part of the native session visible in
OpenWorker Desktop.

Each Mu outbound records the native message cursor that existed when it was queued
and can reconcile only to that index or a later one. REST reconciliation pre-indexes
native positions and hashed direct/Context match keys, so repeated prompt text
cannot steal an older native row and large transcripts do not trigger a nested
full-history scan on every poll.

The Workspace Chat banner displays the native session ID, Agent, model, current
state, and recent Runtime/Ledger activity. Assistant deltas are batched for display.
The native final message replaces transient text, and late deltas are ignored so a
completed turn stops streaming immediately.

## Interactions and interruption

No Runtime decision is automatic.

- `permission_required` becomes an explicit Approve once or Deny action.
- `plan_proposed` becomes Approve plan or Reject.
- `question_requested` accepts a user answer.
- `directory_requested` is displayed, but the grant must be completed in OpenWorker
  Desktop so Mu cannot expand filesystem access on its own.
- Interrupt sends the native `interrupt` message for a Working or Needs approval
  session.

Every non-delta state event and interaction resolution is written to Mu's append-only
ledger with the Task, Run, binding, endpoint, and native session identifiers.
High-frequency assistant/reasoning deltas remain transient UI state until the native
message is reconciled.

## Artifacts

Mu imports OpenWorker artifact metadata: relative and absolute path, name, kind,
byte count, modification time, endpoint, and native session provenance. The
Artifacts surface can reveal a returned local path only after proving it is the
bound workspace itself or a descendant of that workspace.

This is a native metadata mirror, not a claim that the artifact bytes have been
copied into Mu's content-addressed evidence store. A Checkpoint remains the mechanism
for sealing repository evidence into CAS.

## Authentication boundary

The verified 0.1.6 legacy path is tokenless and is intentionally limited to
`127.0.0.1`. Current OpenWorker source builds instead launch Desktop with a random
private token, use `X-OpenWorker-Token` for HTTP, and pass `openworker` plus the token
as WebSocket subprotocols.

The Mu transport can encode those authentication fields, but the 0.6 application
does not expose token entry or secret storage. It never extracts the private token
from OpenWorker Desktop. Consequently, a protected current Desktop sidecar is not a
supported live endpoint in this release. A future authenticated adapter must require
an explicit endpoint and user-provided token rather than weakening this boundary.

## Codex comparison

The Codex adapter remains deliberately different. It can create a native read-only
initial Task or receiving Replan through `thread/start` and `turn/start`, with IDs and
final evidence persisted by stage. It does not expose Workspace Chat routing,
Continue, Cancel, writes, or approvals. In particular, `@Codex` is not an alias for
continuing the initial Codex thread in Mu 0.7.
