# Second runtime probe

Date: 2026-07-27  
Host: macOS arm64

## Claude

Observed:

- `/Applications/Claude.app` is installed.
- No `claude` executable is available on `PATH`.
- The desktop bundle exposes the GUI executable and UI assets, but no documented
  Agent SDK, ACP server, headless CLI, or local session-control binary.

Decision:

- Do not register Claude Desktop as a controlled runtime endpoint.
- Keep Claude transfer at the generic manual Artifact Bridge boundary.
- Do not claim Start, Resume, Replan, event streaming, approval interception, or
  quiescence.
- Re-probe after the user installs Claude Code or explicitly configures an official
  Agent SDK/ACP endpoint.

Mu 0.7's separate Claude Code history adapter does not change that runtime-control
decision. The adapter runs a bounded, read-only scan only after the user chooses
**Find history** for a Task folder. That action is consent to inspect candidate
JSONL records for the selected canonical path; merely opening Mu or the Task does
not scan. Discovery does not copy or send content, and import still requires
selection plus explicit confirmation. Matching is exact canonical-path string
equality after standardization and symlink resolution, not filesystem
device/inode identity. Only visible user/assistant text can become a local
`history_only` copy.

Claude Code is therefore an initial history provider in the Conversation Continuity
Layer, not a live Runtime endpoint. A future injected history provider would have the
same separation: history import alone cannot advertise Start, Continue, streaming,
approvals, or artifact control.

## OpenWorker

Observed on the installed OpenWorker Desktop 0.1.6 compatibility target:

- `/Applications/OpenWorker.app` is installed and exposes its application version
  and bundle identity.
- While the app is running, its log records a random Uvicorn listener on
  `127.0.0.1`.
- The 0.1.6 legacy sidecar accepts tokenless loopback health, Agent, session,
  message, artifact, and session-WebSocket operations.
- A session has a persistent native ID, workspace, Agent, model, messages, liveness,
  attention state, and artifact inventory. The same session can be opened in
  OpenWorker Desktop after Mu creates it, or explicitly linked into Mu when it
  already exists.
- The WebSocket protocol reports readiness, assistant deltas and messages, tool
  progress, permission requests, plan/question prompts, interruption, and terminal
  turn state. REST reconciliation makes native messages, liveness, and artifact
  metadata visible after work is initiated from either application.

Decision for Mu 0.7:

- Discover the application without claiming live control.
- Activate capabilities only after an explicit in-app probe succeeds.
- Restrict tokenless compatibility to `http://127.0.0.1:<port>`; never connect a
  tokenless adapter to a LAN, wildcard, Unix-domain proxy, or remote address.
- Require an explicit create-or-link choice before the first routed Workspace Chat
  message is sent. Confirm a cross-workspace link separately.
- Treat that live cross-workspace confirmation as routing-only. History import and
  Context delivery require exact canonical workspace matches and fail closed.
- Exclude an imported OpenWorker source only when its provider-instance/endpoint,
  native-session, and canonical-workspace envelope exactly matches the target, so
  its transcript is not fed back into itself.
- Persist the Mu Task/Run/Agent/endpoint to native-session binding and mirror
  messages, state, interactions, ledger events, and artifact metadata.
- Surface approve-once and deny decisions; never auto-approve. Keep directory grants
  in OpenWorker Desktop.
- Mark an uncertain post-send outcome ambiguous and do not retry it automatically.

## Current OpenWorker token boundary

Current OpenWorker source builds protect the desktop sidecar with a random launch
token held in memory and injected into the application's own webview. HTTP uses
`X-OpenWorker-Token`; WebSocket clients negotiate the `openworker` subprotocol plus
the token.

Mu's transport types understand those protocol fields, but Mu 0.7 has no
user-authorized token provisioning or secret-storage flow. It does not recover the
desktop token from process memory, logs, the webview, or application state. A
token-protected sidecar therefore fails closed and is not registered as
dispatch-capable. Supporting an explicitly configured authenticated standalone
endpoint remains separate future work.

This distinction is capability-probed, not inferred from the displayed application
version: a protocol update or protected response removes the live capability claim.

## Current validation boundary

- Live endpoint: Codex App Server (`vendor_protocol`) for a new read-only initial
  Task and a receiving read-only Replan.
- Live second endpoint, when the local probe passes: OpenWorker Desktop legacy
  loopback (`vendor_protocol`) for persistent session routing and synchronization.
- Offline independent endpoints: Synthetic Runtime A and B (`synthetic`).
- Unsupported live runtime operations: represented honestly by the Manual Artifact
  Bridge (`artifact_only`).

Codex Workspace Chat continuation is not part of this boundary. `@Codex` must not be
presented as native Continue merely because the initial Task adapter can create a
thread.

See [OPENWORKER_ADAPTER.md](OPENWORKER_ADAPTER.md) for the session and failure
contract.
