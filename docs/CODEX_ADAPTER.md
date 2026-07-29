# Codex App Server adapter

## Verified runtime

- Executable: auto-discovered from ChatGPT, Codex.app, Homebrew, or a standard
  local binary path.
- Verified local CLI: `codex-cli 0.146.0-alpha.3.1`.
- Transport: child-process stdio, one JSON object per line.
- Protocol contract: generated locally with:

```sh
codex app-server generate-json-schema --experimental --out docs/codex-app-server-schema
codex app-server generate-ts --experimental --out docs/codex-app-server-ts
```

## Probe

Mu sends:

1. `initialize`
2. `initialized`
3. `account/read`
4. `thread/list`

The endpoint becomes `active` only when initialization succeeds and an authenticated
account is observable. Mu stores runtime version, probe time, endpoint state, and
capability evidence, but does not copy account email or credentials into its ledger.

## Native read-only Task

When a user creates a Task on the active Codex endpoint, Mu creates its local Task
and Run records first, then sends:

1. `thread/start`
2. `turn/start`

Both are scoped to the selected repository. The thread and turn use:

- `sandbox: read-only`
- `approvalPolicy: never`
- `approvalsReviewer: user`

The prompt contains the Task objective, success criteria, constraints, pending work,
and the selected Mu Agent identity and role. Role injection is task context, not a
claim that Codex has adopted a vendor persona.

Mu persists the native thread ID immediately after `thread/start` and the native
turn ID immediately after `turn/start`. This staged persistence keeps the last
confirmed protocol identity available even if a later event fails or times out. Mu
consumes the completion events, stores the final output in its content-addressed
evidence store, and appends the corresponding Task, Run, native-ID, output-hash, and
completion facts to the execution ledger.

## Receiving Replan

After the user accepts a Handoff to the active Codex endpoint, Mu uses the same
`thread/start` and `turn/start` sequence and the same staged native-ID persistence.
The receiving prompt contains the sealed Checkpoint JSON and explicitly prohibits
commands, tools, and artifact mutations. Mu consumes `item/completed` and
`turn/completed`, then records:

- native thread ID;
- native turn ID;
- native completion status;
- final receiving plan;
- causal ledger events.

Execution after plan approval is intentionally separate. Mu 0.7 never silently turns
a read-only Task or Replan into a workspace-writing turn.

## Project history boundary

Mu 0.7 discovers prior Codex conversations through the official App Server
`thread/list`, using the Task's canonical `cwd`, and reads only sessions the user
selects. A match is exact path-string equality after standardization and symlink
resolution, not filesystem device/inode identity. Import copies visible user text
and commentary/final-answer text only; reasoning, command, and tool items stay out.

Imported Codex history can supply reviewed, bounded Context to a supported target
Runtime, but Mu does not present that as Codex Continue. Generated Context plaintext
is staged only during target dispatch; the durable receipt retains hashes, IDs, and
counts rather than the Context body.

Codex is one initial source in Mu's provider-neutral Conversation Continuity Layer.
Its stable raw provider ID is `codex`. The generic `ConversationHistoryAdapter`
injection point allows other compiled history integrations, but does not change this
Codex adapter's separate live capability boundary.

## Capability boundary

The Codex adapter implements capability discovery, an initial read-only Task turn,
and a receiving read-only Replan. It does not implement Continue, Cancel, workspace
writes, workspace-chat dispatch, or approval responses. The five Mu-owned workspace
surfaces—Chat, Files, Browser, Terminal, and Artifacts—remain available independently
of those native protocol capabilities.

## Failure behavior

- A failed probe leaves the endpoint `degraded`.
- A missing authenticated account cannot be scheduled.
- A failed or timed-out Task or Replan preserves any staged native IDs. Once native
  identity exists, Mu marks the Run `ambiguous` and disables automatic retry;
  failures before native creation use `failed` or `degraded` as appropriate.
- Mu never auto-approves a server-initiated permission request.
- Checkpoint and prior ledger records remain immutable.
