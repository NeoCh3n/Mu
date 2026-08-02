# Mu UI contract

The TypeScript web surface and the native macOS surface intentionally share
one information architecture. The implementations can use platform controls,
but the user-visible vocabulary and state guarantees stay aligned.

## Navigation

Both surfaces expose the same sections in this order:

`Overview` · `Agents` · `Projects` · `Handoffs` · `Runtimes` · `Ledger`

`Task` is a conversation/execution record nested inside a `Project`; it is not
a top-level navigation section. Existing `/tasks` links remain valid for deep
links and compatibility.

## Runtime identity

An endpoint is one concrete runtime instance. Whenever an endpoint is shown,
the UI should prefer the same fields in this order:

1. `instanceLabel`
2. `surfaceKind` (`Desktop`, `CLI`, `Editor`, …)
3. `terminalIdentifier` when present
4. `stableInstanceKey` as the compact diagnostic fallback

This is what distinguishes the single Codex Desktop instance from multiple
Codex/Claude Code terminal instances.

## Project and workspace surfaces

Projects expand/collapse to reveal their Tasks/conversations. A selected Task
opens a workspace with these surfaces:

`Chat` · `Files` · `Browser` · `Terminal` · `Artifacts`

The Chat surface owns `@Codex`/`@Claude Code` routing, Markdown output,
Context Pack selection, imported-history progress, and the current endpoint
badge. The right inspector owns runtime boundary, Runs, Context Pack,
Artifacts, Handoffs, and Ledger state.

## Status vocabulary

The same state words are used in both clients: `Ready`, `Running`, `Blocked`,
`Completed`, `Failed`, `Cancelled`, and `Handoff pending`. Status colors are
semantic, not provider-specific: violet for control/active work, mint for
healthy or delivered, coral for handoff/attention, and red for failures.

## Reasoning effort

Effort is a per-turn routing concern, not a Project setting. The TypeScript
control-plane surface exposes `Auto`, `Medium`, `High`, and `Ultra`; `Auto`
uses the task shape heuristic and the resolved value is recorded on the Run.
The native Swift surface keeps the provider's native default for now, so it
does not pretend that an explicit effort value was sent when the host protocol
does not expose one. Both clients use the same provider-neutral vocabulary and
the native adapter can adopt the recorded value without changing the UI
contract when that protocol support is enabled.
