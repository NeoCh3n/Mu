# Conversation Continuity Layer

Mu's Conversation Continuity Layer is a provider-neutral intermediate layer between
native Agent history and a Project's reviewed cross-Agent Context. It keeps imported
history separate from live Runtime state. An imported conversation is not a Run,
Runtime session binding, Checkpoint, Handoff, or claim that an Agent is currently
working.

The layer owns canonical workspace matching, normalized visible messages, native
provenance, revision detection, explicit selection, local persistence, bounded
Context composition, and delivery receipts. Native formats remain behind adapters.
This lets a Project carry reviewed inputs and outputs across Agent changes without
pretending that private model state, reasoning, tools, or a live native session is
portable.

## Extensibility contract

`ConversationProvider` is a `RawRepresentable` string value. Mu reserves the
built-in IDs `codex`, `claude_code`, and `openworker`, but decoding and persistence
accept other stable raw IDs. Unknown registered providers use a derived display name
and generic history styling instead of requiring a provider-specific persistence or
UI case.

`ConversationHistoryAdapter` is the in-process injection contract for an additional
history source:

- `provider` supplies its stable raw provider ID;
- `providerInstanceKey` distinguishes installations or endpoints;
- `discoverConversationHistory(canonicalWorkspacePath:)` returns candidates for the
  exact requested workspace;
- `hydrateConversationHistory(_:)` loads visible messages after selection.

Mu injects adapters when constructing `ControlPlaneService`. This is a source-level
extension point for compiled integrations, not a dynamic plugin marketplace or a
sandbox for untrusted adapter code. Discovery must therefore be metadata-only and
independently bounded. On discovery and hydration Mu
rejects a changed provider instance, native session identity, or workspace, and the
common hydration gate re-bounds the candidate before import.

Injected adapters cannot reuse Mu's reserved built-in provider IDs. Registrations
must have bounded provider and instance identities, and a provider-instance pair may
be registered only once.

An adapter must normalize its native format to `user` and `assistant` messages and
must not relabel system, developer, reasoning, thinking, tool, credential, or hidden
content as visible text. The three built-in paths implement their own native-format
filters. Mu validates the normalized role and identity model, but an injected
adapter remains responsible for the semantic correctness of that normalization.

Adding a history adapter does not create a live Runtime adapter. Start, Continue,
streaming, cancellation, approvals, credential handling, artifact discovery, and
native-session synchronization remain separate, capability-probed contracts.
`ConversationResumability.resumable` describes the native source; it is not a claim
that Mu can resume it.

## Discovery

Project creation begins with a selected folder and an optional set of history
providers. Workspace Chat exposes the same source selector through **Find history**.
Both flows canonicalize the Task folder, including symlink resolution, and ask only
the selected providers:

- **Codex** — official local App Server `thread/list` with the canonical `cwd`,
  complete active/archived pagination, followed by `thread/read` only for sessions
  the user selects.
- **OpenWorker** — the already-probed loopback REST API
  `GET /v1/sessions?workspace=…`, followed by the selected session's messages.
- **Claude Code** — a bounded read-only adapter over
  `CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`. It validates the `cwd`
  inside each JSONL record instead of trusting only the encoded directory name,
  never follows history-directory symlinks, reads in 64 KiB chunks, and reports a
  damaged tail while retaining earlier valid records.
- **Injected providers** — each registered `ConversationHistoryAdapter` is asked
  independently with the same canonical path. Candidates whose provider ID,
  provider-instance key, or exact workspace conflicts with the registered adapter
  are rejected.

Every candidate also carries an `AgentRuntimeInstanceIdentity`. It keeps the Agent
product separate from the concrete surface and instance:

- Codex `appServer`, `cli`, `exec`, and `vscode` thread sources remain distinct;
- the local Codex Desktop application has one desktop-instance identity;
- Codex CLI and Claude Code CLI histories use stable native-session/source-file
  evidence so multiple CLI sessions do not collapse together;
- a concrete TTY or terminal label is authoritative only when the Runtime or user
  supplied it; otherwise Mu explicitly reports that the terminal was not recorded;
- older imported records resolve the same non-overclaiming identity from their
  existing provider, endpoint, session, workspace, and source fields.

Selecting providers while importing a Project folder, or choosing **Find history**,
is the user's consent for only those registered adapters to perform their documented
discovery for that selected Project folder. The UI reports provider-level completion
through a determinate read-only-check progress bar. Mu does not scan merely because
the app or an existing Task opens, does not continuously watch the Claude
configuration directory, and does not persist an imported local copy or send
discovered content until the user selects conversations and confirms the import.

The latest discovery result is held in an in-memory authorization cache so import
cannot substitute a forged candidate. It may contain message bodies when a built-in
or injected adapter hydrates eagerly. Mu keeps results for at most two Tasks and
discards a Task's result on cancel or successful import; it is not a durable history
copy.

Workspace matching is canonical-path exact: Mu standardizes paths, resolves
symlinks, and then compares the resulting strings. It is not filesystem physical
identity and does not compare device/inode identity. `/repo` does not match
`/repo2`. Beyond symlink resolution, different resulting strings—including
separate worktrees—are not merged automatically.

## Content boundary

Mu copies only visible user and assistant text:

- Codex user text and visible commentary/final-answer items;
- Claude Code user/assistant string or text blocks;
- OpenWorker user/assistant content.

Mu excludes Codex reasoning, commands and tools; Claude thinking, sidechains,
tool-use/tool-result, system reminders and system messages; and OpenWorker reasoning,
tool messages and credentials. Source files and native sessions remain unchanged.

The import sheet selects nothing by default. A second explicit confirmation both
copies the selected text into Mu's local SQLite database and enables it for future
cross-Agent Context. A user can later disable a source without deleting it, or
remove Mu's copy without affecting the provider.

## Resource bounds

Import and Context delivery have separate limits:

| Stage | Current bound |
| --- | --- |
| Common hydrated conversation gate | 50,000 visible messages, an 8 MiB source-text truncation threshold per message, and 64 MiB retained visible text per conversation |
| Claude Code discovery | Two preferred encoded project directories; if they yield no exact match, at most 256 fallback directories. Each phase examines at most 2,048 JSONL files. Parsing is further bounded to 250,000 records per file, 8 MiB per record, 512 retained candidates, 100,000 retained messages, and 64 MiB retained text |
| Claude Code per-session assembly | 50,000 messages and 64 MiB text; an individual native message is first limited to 1,000,000 characters |
| Injected-adapter discovery | 512 metadata-only candidates per adapter, 64 KiB metadata per candidate, 64 warnings, and no message bodies before selection |
| Discovery authorization cache | Latest results for at most two Tasks |
| Context source/window query | Up to 512 enabled source rows, at most 80 conversations, up to 1,600 recent candidate rows, and up to one first-user anchor per conversation |
| Delivered Context pack | 32 KiB UTF-8 total, 80 messages, and 8 KiB per message |

The Claude reader streams in 64 KiB chunks and does not follow symlinks from its
history tree. When a bound is reached, Mu retains the accepted prefix/window, records
warnings or omission/truncation counts, and does not silently advertise the omitted
content as imported. The common gate limits hydrated content before persistence, but
an injected adapter must also bound its own native discovery and parsing work because
it executes inside Mu's process.

## Persistence and refresh

Imported conversations, individual messages, and per-Task Context selections use
dedicated SQLite tables. Imported visible text is an explicit local copy. Context
snapshot receipts use a separate table, but their durable form contains target and
source IDs, the selection fingerprint, SHA-256, byte count, omission count, and
truncation count—not the generated Context plaintext. Conversation identity is
provider instance + native session + canonical workspace. Codex and Claude retain
native item IDs. OpenWorker uses session + source ordinal + role/content hash, so
two identical prompts at different ordinals remain distinct.

The provider raw ID is stored with the imported conversation, so an injected
provider does not need a schema migration merely to preserve its identity. The
adapter must still be registered again to rediscover or rehydrate native content.

Re-import is idempotent. Append-only growth is accepted. If a provider changes or
removes an already-reviewed item, Mu preserves the prior local snapshot, marks the
source changed, and requires the user to review it rather than silently rewriting
Context. Removing a Runtime from the registry does not remove already-imported
history.

Removing an imported conversation deletes Mu's local visible-text copy and disables
it as a Context source. Mu also clears any unsent transient Context payload derived
from that source and redacts legacy local payload fields. This cannot recall a
Context envelope that was already delivered to, and may be retained by, a native
Runtime session.

## Cross-Agent delivery

Context is target-aware and generated at send time, not at import time:

1. exclude disabled sources and an OpenWorker source whose exact provenance
   envelope—provider instance/endpoint, native session ID, and canonical
   workspace—matches the target envelope;
2. retain the first user request and the newest eligible visible messages;
3. cap each message at 8 KiB, the pack at 80 messages and 32 KiB UTF-8;
4. encode a deterministic JSON reference with Task objective, success criteria,
   constraints, pending steps, provider/session provenance, and explicit omission
   and truncation counts;
5. label the history as untrusted quotation, not system/developer instruction;
6. attach it only once for the selected source revisions and native binding.

The generated Context plaintext is staged only for the native dispatch interval and
is redacted when delivery is accepted, rejected, or becomes ambiguous. Mu durably
persists only the receipt: SHA-256, target/source and included-message IDs, byte
count, omission count, and truncation count. The ledger likewise records only those
identifiers and counts, never the Context body. The Workspace Chat row exposes that
receipt. If delivery becomes ambiguous, the existing no-automatic-retry rule applies
to the combined Context and current request.

This in-memory rule applies to the generated Context envelope, not to the reviewed
history itself: imported visible user/assistant messages are intentionally stored as
a local SQLite copy until the user removes them.

Context delivery is fail-closed across workspaces. Both the imported source and the
target binding must exactly match the Task's canonical workspace; a live
OpenWorker session link that the user separately confirmed for another workspace
does not authorize history import or Context delivery there.

Codex history may be natively resumable in Codex, but Mu 0.7 still does not claim an
`@Codex` Workspace Chat continuation adapter. Claude Code is explicitly
`history_only`. OpenWorker has both a history source and a separately verified live
Runtime adapter. An unknown injected provider is history-only from Mu's perspective
unless a distinct Runtime integration proves its capabilities. Any of these history
sources can provide reviewed Context to a supported target Runtime without
pretending Mu controls their native sessions.
