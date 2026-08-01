# Mu Runtime Gateway

`RuntimeGatewayManifest` is the provider-neutral contract between the Project
Kernel and one concrete Runtime endpoint. Every operation is declared as
`supported`, `conditional`, or `unsupported`; unknown adapters fail closed.

The manifest separates:

- connection kind: managed Runtime, connected Agent, or tool host;
- control mode: managed, managed-limited, attached, history-only, submit-only;
- trust: managed, connected, submit-only;
- observation fidelity: native stream, mirrored stream, polling, snapshot,
  none;
- concrete operations such as session creation/attachment, input, events,
  resume, interrupt, approval, Artifact access, Lease heartbeat, and Task
  completion;
- Mu-hosted `context.search` and `context.get_record`, which are conditional
  capabilities for Codex, Claude Code, and OpenWorker.

## Built-in adapters

| Runtime | Boundary | Native identity | Current control |
| --- | --- | --- | --- |
| Codex | managed-limited official App Server | persistent thread + turn | history, read-only initial turn and continuation, mirrored visible result, interrupt, Project Artifact |
| Claude Code | managed-limited CLI | CLI instance + UUID session | history, read-only `stream-json` initial turn and resume, batched visible output, process interrupt, Project Artifact |
| OpenWorker | connected Agent, attached sidecar | exact-workspace desktop session | create/link session, native events, input, approvals, artifacts, resume, interrupt |

Codex and Claude Runtime cards can represent one desktop endpoint and multiple
specific CLI endpoints. Registration stores surface kind, user-visible instance
label, optional terminal identifier, executable, and persistent endpoint UUID.
When multiple endpoints share a provider, Workspace Chat uses an
instance-specific stable mention rather than guessing.

## Runtime Context Gateway

Runtime adapters call `runtimeContextSearch(bindingID:query:limit:)` and
`runtimeContextRecord(bindingID:recordID:)`. They never submit a Project,
Task, Actor, Principal, Endpoint, Run, Workspace, Lease, or Context Pack ID.
Mu derives every authority boundary from the persisted binding.

Both operations fail closed unless all of the following still agree:

- the binding is `working`, its Run is `active`, and its endpoint is active;
- the endpoint-bound Actor and Principal are active Project participants;
- Task, active Workspace, fenced Lease, Run, binding, and immutable governed
  Context Pack identities match exactly;
- the Pack's rendered CAS object and SHA-256 receipt verify;
- the exact Pack/Run/binding tuple has a `delivered` receipt with an adapter
  receipt. A merely `prepared` Pack is deliberately insufficient.

After this boundary check, normal Context policy filtering runs again.
`context.get_record` returns no distinction between a nonexistent record and a
record hidden by policy.

## Context and output boundary

The Gateway receives an immutable, policy-filtered Mu Context Pack. Imported
Agent history remains provenance and candidate input; it is not concatenated
into one shared transcript or treated as Project truth. The Runtime's
transcript remains Runtime state.

Visible output is mirrored into Chat for usability, but the durable handoff
unit is a Project Artifact. Reasoning, thinking, tool internals, system
messages, and developer instructions are not portable context.

## Future BYOA

A future remote Agent implements the same manifest plus registration,
authentication, signed events, heartbeat, and task-scoped credentials. It
starts as `connected` or `submit-only`; MCP may expose Project tools and
resources but does not replace Membership, Delegation, Lease, Workspace,
Review, Approval, or trust policy.
