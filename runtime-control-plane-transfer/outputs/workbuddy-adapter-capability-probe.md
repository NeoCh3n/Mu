# WorkBuddy Adapter Capability Probe

Status: REQUIRED BEFORE CLAIMING CONTROLLED INTEGRATION  
Target runtime type: `workbuddy`  
Related but distinct runtime type: `codebuddy_code`

## Decision to Make

Determine the strongest honest integration level:

1. **Controlled adapter** — stable official or observable programmatic session/control surface.
2. **Artifact-only adapter** — reconstructable workspace evidence but no reliable live control.
3. **Manual bridge** — user-selected artifacts and manually confirmed Checkpoint only.
4. **Unsupported** — transferred state cannot be reconstructed safely enough for Codex Replan.

Do not infer WorkBuddy capabilities from CodeBuddy Code documentation. Test them as separate runtime endpoints.

## Safety Rules

- Use a disposable repository and synthetic files.
- Do not inspect credentials, tokens, private conversations, or unrelated application data.
- Do not modify application binaries or bypass access controls.
- Record only documented endpoints or locally observable process metadata needed for interoperability.
- Do not use production tasks as fixtures.
- Treat every unverified behavior as `unknown`, not `unsupported`.
- Treat MCP servers and Connectors as WorkBuddy’s outbound tool integrations unless evidence proves they also expose WorkBuddy as a controllable agent.

## Environment Record

- Probe date and timezone:
- WorkBuddy product edition:
- WorkBuddy version:
- Operating system:
- Account tier:
- Enabled feature flags:
- Test workspace:
- Disposable repository base commit:
- Probe operator:

## Passive Discovery

### Product and Process

- Installed application identifier and version:
- Documented CLI entry point:
- Documented SDK:
- Documented HTTP, WebSocket, SSE, JSON-RPC, ACP, or local socket:
- Stable runtime endpoint identifier:
- Stable task identifier:
- Stable session identifier:
- Supported export formats:
- Application process names:
- User-visible task storage location, if documented:

### Workspace and Artifact Boundary

- Can a task be bound to an explicit workspace directory?
- Can the product work directly in a Git repository?
- Are base/head commits observable?
- Are tracked modifications reconstructable?
- Are untracked files reconstructable?
- Are generated documents and binary artifacts addressable?
- Can the user request a quiescent point before Capture?
- Can the source machine shut down after Capture without losing required evidence?

### Session and Context Boundary

- Can external software list tasks or sessions?
- Can external software retrieve task status?
- Can external software retrieve a transcript or structured event history?
- Can external software resume a specified task/session?
- Can external software subscribe to progress or completion events?
- Can external software cancel or pause an active task?
- Can external software prove that no mutation remains in flight?

### Permission Boundary

- Native permission model: `fine_grained | prompt_gate | all_or_nothing | none | unknown`
- Are permission requests observable?
- Can an external client answer a request?
- Can tool/action categories be mapped to PermissionIntent?
- Can read-only Review be enforced?
- Can artifact writes be prohibited for a reviewer?

## Active Disposable-Repository Tests

| Test | Expected evidence | Result | Capability status |
|---|---|---|---|
| Create task in selected workspace | Stable task/workspace reference |  |  |
| Read one file | Observable action or before/after evidence |  |  |
| Modify one tracked file | Reconstructable diff and actor evidence |  |  |
| Create one untracked file | Manifest path, size, mode, and hash |  |  |
| Request a sensitive action | Observable permission behavior |  |  |
| Pause or reach explicit quiescence | Native acknowledgement or documented absence |  |  |
| Resume same task | Stable session/task identity |  |  |
| Export or reconstruct task context | Objective, decisions, constraints, pending work |  |  |
| Close WorkBuddy after valid Capture | Checkpoint remains sufficient |  |  |
| Start Codex from the Checkpoint | Correct Replan without prohibited new context |  |  |

## CodeBuddy Code Comparison

Test separately whether `codebuddy_code` can supply a stronger adapter through:

- ACP server mode;
- Agent SDK;
- Beta HTTP Run/session/event APIs;
- CLI stream output;
- documented permission and session controls.

Record:

- interface selected:
- official documentation version:
- session identity behavior:
- event ordering and IDs:
- command acknowledgement:
- cancellation semantics:
- permission interception:
- artifact evidence:
- capability expiry trigger:

Finding CodeBuddy Code support does not change WorkBuddy’s result unless a documented or observed supported bridge proves they share the same controllable session.

## Capability Matrix

| Capability | native | emulated | unsupported | unknown | Evidence |
|---|---:|---:|---:|---:|---|
| list_tasks |  |  |  |  |  |
| attach_workspace |  |  |  |  |  |
| start |  |  |  |  |  |
| resume |  |  |  |  |  |
| pause |  |  |  |  |  |
| cancel |  |  |  |  |  |
| stream_events |  |  |  |  |  |
| observe_permissions |  |  |  |  |  |
| answer_permissions |  |  |  |  |  |
| prove_quiescence |  |  |  |  |  |
| contribute_checkpoint_evidence |  |  |  |  |  |
| discover_artifacts |  |  |  |  |  |
| enforce_read_only_review |  |  |  |  |  |

## Artifact-Only Fallback Contract

If no supported control interface exists, the adapter may implement only:

- user selects the WorkBuddy task workspace;
- control plane records objective, constraints, decisions, and pending work with user confirmation;
- adapter captures base/head commit, tracked diff, untracked manifest, generated artifacts, and hashes;
- user confirms WorkBuddy has stopped mutating the workspace;
- Checkpoint is marked `non_exclusive` unless quiescence can be proven;
- Codex always starts a new Run and Replans;
- all live-event, pause, approval, fencing, and native-resume capabilities remain `unsupported` or `unknown`.

This fallback satisfies portable work continuation. It does not make WorkBuddy a fully controlled member of the runtime mesh.

## Final Decision

- Integration level:
- Supported capabilities:
- Emulated capabilities and weaker guarantees:
- Unsupported capabilities:
- Unknown capabilities:
- Permission model:
- Can WorkBuddy → Codex be enabled by default?
- Required user confirmations:
- Required isolation:
- Re-probe trigger:
- Evidence hashes:
- Decision owner:
- Decision date:
