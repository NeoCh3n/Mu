# Mu 0.7.1 Design QA

## Comparison target

- Source visual truth:
  - `/Users/neo/Desktop/Mu/build/ux-audit/09-after-task-status-groups.jpeg`
  - `/Users/neo/Desktop/Mu/build/ux-audit/08-after-runtime-registry.jpeg`
  - The user-provided sidebar screenshot establishes the requested `Tasks` → `Projects` copy change; the two local pre-change captures provide the same app states at a directly comparable viewport.
- Rendered implementation:
  - `/Users/neo/Desktop/Mu/build/ux-audit/25-final-projects-migrated.png`
  - `/Users/neo/Desktop/Mu/build/ux-audit/26-final-runtime-registry.png`
  - `/Users/neo/Desktop/Mu/build/ux-audit/27-final-new-project.png`
  - `/Users/neo/Desktop/Mu/build/ux-audit/17-agent-instance-import.png`
- Viewport: native macOS window capture, 1299 × 768 pixels.
- Source pixels: 1299 × 768 for each pre-change capture.
- Implementation pixels: 1299 × 768 for each full-window implementation capture.
- CSS size: not applicable to this native SwiftUI app.
- Density normalization: source and implementation were captured by the same macOS automation surface at identical pixel dimensions and compared 1:1 without rescaling.
- State: dark appearance; Projects list with a failed Project selected; Runtime registry with three active cards; New Project sheet; exact-folder Codex history review.

## Evidence

### Full-view comparisons

- Projects before/after:
  `/Users/neo/Desktop/Mu/build/ux-audit/28-final-projects-comparison.png`
- Runtime registry before/after:
  `/Users/neo/Desktop/Mu/build/ux-audit/30-final-runtimes-comparison.png`

The overall navigation, three-column workspace hierarchy, typography, spacing, colors, selected states, and content density remain consistent with the existing Mu design. The intended terminology and runtime-identity changes do not alter the established composition.

### Focused comparisons

- Sidebar and Project list:
  `/Users/neo/Desktop/Mu/build/ux-audit/29-final-projects-focused.png`
- Runtime cards:
  `/Users/neo/Desktop/Mu/build/ux-audit/31-final-runtimes-focused.png`

Focused evidence was required because the changed labels and Runtime metadata are too small to judge reliably in the full-window pair. It confirms:

- `Tasks` is now `Projects` in the sidebar and list title.
- Count labels use `project`/`projects` correctly.
- Codex is labelled `Codex Desktop` instead of exposing the App Server transport as the user-facing instance.
- Runtime cards have a uniform height and aligned action rows.
- Surface and identity-basis metadata fit without changing the grid.

The New Project sheet separately confirms explicit `Desktop`, `CLI`, `exec`, `editor`, and native-session source language. The history review confirms that five folder-related Codex VS Code conversations are displayed as five distinct editor-session instances.

## Required fidelity surfaces

- Fonts and typography: unchanged native system font, optical weights, hierarchy, wrapping, and line height. `Projects` fits the same navigation and title slots without truncation.
- Spacing and layout rhythm: sidebar metrics, list width, card padding, section gaps, radii, dividers, and three-column workspace proportions remain consistent. Runtime cards are equal-height and their bottom actions align.
- Colors and visual tokens: existing purple selection/CTA token, dark surfaces, status colors, borders, and contrast are unchanged.
- Image quality and asset fidelity: native SF Symbols remain sharp and unchanged. The supplied Mu artwork is preserved verbatim as the source asset and compiled into a macOS Retina icon with transparent outer corners.
- Copy and content: `Project/Projects` now identifies repository-folder containers, while `Task/Tasks` identifies the runnable work inside them. Provider-native Codex thread/turn and OpenWorker session terms remain intact.
- Accessibility: sidebar and controls retain semantic labels and focusable native controls. Project rows announce Task counts and expanded/collapsed state; Task rows announce status and Agent, with exactly one selected Task trait.
- Interaction states: Projects selection, Project expand/collapse, Task selection, Project-scoped New Task opening/cancel, Runtime selection, source toggles, provider-selective read-only history discovery, and disabled import/create actions were exercised.

## Findings

No actionable P0, P1, or P2 findings remain.

- P3 follow-up polish: long Runtime capability chips remain horizontally scrollable and may be partially clipped at rest in narrow cards. This behavior predates the change and does not hide persistent controls or affect the requested uniform card sizing.

## Comparison history

### Iteration 1

- Earlier P2: accessibility labels announced `Completed, 1 projects` and `Closed, 1 projects`.
- Fix: added singular/plural Project count labels in `TasksView`.
- Post-fix evidence: final accessibility tree reports `Completed, 1 project` and `Closed, 1 project`; visual evidence is the final Projects capture.

- Earlier P2: an existing persisted Codex Runtime guarantee still displayed legacy `Tasks` wording after the source strings were renamed.
- Fix: added a startup migration for the built-in Codex endpoint and a regression test.
- Post-fix evidence: `/Users/neo/Desktop/Mu/build/ux-audit/25-final-projects-migrated.png` and `/Users/neo/Desktop/Mu/build/ux-audit/26-final-runtime-registry.png` display `Initial read-only Project runs`.

### Final pass

- No new P0/P1/P2 differences were found in the full-view or focused comparisons.
- The final native app remained responsive through the primary interactions listed above.

## Agents uniform-card follow-up

- Source visual truth:
  `/Users/neo/Desktop/Mu/build/ux-audit/32-agents-before-uniform-height.png`
- Final implementation:
  `/Users/neo/Desktop/Mu/build/ux-audit/36-agents-final-uniform-cards.png`
- Full-view comparison:
  `/Users/neo/Desktop/Mu/build/ux-audit/37-agents-uniform-height-comparison.png`
- Focused card comparison:
  `/Users/neo/Desktop/Mu/build/ux-audit/38-agents-uniform-height-focused.png`
- Viewport and pixels: both native macOS captures are 1299 × 768 pixels from the same automation surface; no rescaling or density conversion was used.
- State: dark appearance, Agents selected, three registered Agents, Atlas with one active Task, Relay and Scout with none.

The focused comparison confirms that all three Agent cards now share the same top and bottom edges, metadata dividers align, and every Create Project button uses the same baseline. Two-line summary space and the horizontal capability strip keep longer content from changing card height.

Required fidelity surfaces were rechecked:

- Typography: native system hierarchy is preserved; names, roles, availability, summaries, and tags remain readable without multi-line status or tag pills.
- Spacing and layout: all cards use one 326-point content height; the flexible middle space keeps the active-Project row near the bottom while aligning primary actions.
- Colors and tokens: per-Agent accents, material surfaces, dividers, and status colors are unchanged.
- Images and icons: existing initials and SF Symbols remain sharp and unchanged; no replacement assets were introduced.
- Copy and accessibility: full summaries and roles remain available through native help text; capability scroll areas expose a combined accessibility label.

Comparison history:

- Earlier P2: cards followed their content height, so Atlas was taller than Relay and Scout and the primary buttons did not align.
- Fix: reserved one card content height and added flexible space before the active-Project/action area.
- Earlier P2: long capability and availability labels wrapped inside pills.
- Fix: capability tags now use a fixed-height horizontal strip and availability pills keep their intrinsic size.
- Earlier P2: preserving the full availability pill initially cramped the Atlas role label.
- Fix: stacked the delete control and availability pill in the trailing utility column, restoring one-line role text.
- Post-fix evidence: the final implementation and focused comparison paths above show equal card height, aligned actions, one-line pills, and no clipped persistent controls.

## App-icon follow-up

- Supplied source asset:
  `/Users/neo/Desktop/Mu/Resources/AppIconSource.png`
- Transparent production master:
  `/Users/neo/Desktop/Mu/Resources/AppIconRGBA.png`
- Compiled macOS resource:
  `/Users/neo/Desktop/Mu/Resources/AppIcon.icns`
- Transparent-background preview:
  `/Users/neo/Desktop/Mu/build/ux-audit/39-app-icon-transparent-preview.png`
- Final Finder evidence:
  `/Users/neo/Desktop/Mu/build/ux-audit/41-finder-app-icon-final.png`
- Source and output pixels: the supplied source is 1254 × 1254 pixels; the compiled Retina family covers 16 through 1024 pixels.
- State: Finder icon view, native light appearance, final signed Mu 0.7.1 Build 11 application bundle.

The supplied artwork is now the bundle icon. Its connected black outer canvas was converted to transparency while the white rounded-square artwork and all interior shadows, highlights, and colored details were preserved. Finder renders the result as a native app icon without a black square around it.

Required fidelity surfaces were rechecked:

- Image quality: the 1024-pixel Retina source remains sharp and the full standard 16/32/128/256/512-point macOS icon family is present.
- Shape and alpha: all four exterior corners are transparent; the intended white squircle and its soft edge remain intact.
- Recognizability: the M/μ mark and four orbit nodes remain legible at Finder size.
- Bundle integration: `CFBundleIconFile` resolves to the packaged `AppIcon.icns`; `iconutil` can extract the complete iconset and strict code-sign verification passes.

Comparison history:

- Earlier P2: using the supplied RGB image directly would have displayed its black corner canvas as a square in Finder and the Dock.
- Fix: preserved the original source, derived an RGBA production master by removing only the border-connected dark canvas, and rebuilt every required Retina size.
- Post-fix evidence: the transparent preview and final Finder capture above show a clean native silhouette with no remaining black corners.

## Project → Tasks tree follow-up

- Source visual truth:
  `/Users/neo/Desktop/Mu/build/ux-audit/42-projects-tree-reference.png`
- Final full-window implementation:
  `/Users/neo/Desktop/Mu/build/ux-audit/45-projects-tree-reference-state-final.jpeg`
- Final focused implementation:
  `/Users/neo/Desktop/Mu/build/ux-audit/46-projects-tree-focused-final-212.jpeg`
- Normalized comparison:
  `/Users/neo/Desktop/Mu/build/ux-audit/48-projects-tree-normalized-comparison.jpeg`
- Pixels and normalization: source 522 × 648 pixels; native implementation 1299 × 768 pixels. For the focused comparison, the source was proportionally resampled to 212 × 263 pixels and the app-owned Project column was cropped to the same 212 × 263 pixel region after excluding native title-bar chrome.
- Native layout: the Project split column reports a 250-point width; Project rows use a 34-point minimum height and Task rows use a 36-point minimum height.
- State: dark Mu appearance, Projects selected, `Mu` expanded with one selected Task, `WorkspaceSmoke` collapsed.

The reference is used as the information-architecture target rather than a request to replace Mu's established dark appearance. Both sides now present folder-backed Project rows, indented Task children, a rounded selected Task state, compact single-line titles, and collapsed sibling Projects.

Required fidelity surfaces:

- Fonts and typography: native macOS system typography is preserved. Project names use semibold subheadline hierarchy; Task titles use compact subheadline text with tail truncation and full-title help at narrow widths.
- Spacing and layout rhythm: the former multi-line cards and global Active/Completed/Closed sections are removed. Compact 34/36-point rows, fixed status slots, 7–9-point row insets, and a 9-point selected radius match the reference hierarchy while retaining Mu's column proportions.
- Colors and visual tokens: the source uses a light neutral surface; the implementation intentionally retains Mu's existing dark material and violet selection token. State icons add semantic mint/red/blue/gray without relying on color alone.
- Image quality and asset fidelity: the tree uses native SF Symbols for disclosure, folder, add, and status affordances. No raster placeholder, custom SVG, CSS drawing, or substituted product imagery is present.
- Copy and content: Project is the folder container; Task is the selectable work unit. Counts report both entities, and the detail inspector is now `Task context`.
- Accessibility and interaction: Project controls expose Task counts plus Expanded/Collapsed values; collapsed Task nodes leave the accessibility tree; Task rows announce status and Agent; only the current Task carries `.isSelected`. Expand, collapse, cross-Project Task selection, Project-scoped New Task, cancel, and relaunch persistence were exercised.

Comparison history:

- Earlier P1: the screen was a flat collection of Task cards split into Active, Completed, and Closed sections, so renaming the title to Projects did not create Project hierarchy.
- Fix: added a canonical repository-path Project catalog and rendered each Project as a disclosure row with its Tasks nested beneath it. Projects sort by latest activity; active Tasks precede terminal Tasks.
- Earlier P2: there was no direct way to create another Task inside an existing Project.
- Fix: added a visible per-Project add control and a Project-scoped New Task sheet whose folder is fixed to that Project.
- Earlier P2: the accessibility selected trait could remain on a previously selected Task after switching Projects.
- Fix: explicitly adds and removes `.isSelected` as selection changes. Post-fix native AX evidence reports exactly one selected Task.
- Earlier P2: Project and Task copy remained conflated across Overview, Agent cards, Task context, Runtime guarantees, and Handoffs.
- Fix: Project now means the folder container; lifecycle, ownership, Runtime Runs, Checkpoints, and Handoffs consistently refer to the Task.
- Post-fix visual evidence: the full-window, focused, and normalized comparison paths above show the final hierarchy. Post-fix behavioral evidence: 70 tests across 6 suites pass, including six new Project-catalog tests.

No actionable P0, P1, or P2 findings remain.

- P3 follow-up polish: per-Project add buttons make Task creation discoverable but are denser than the supplied reference, which shows trailing actions primarily on the selected row.

## Build 14 — Project actions and history-context clarity

- Source visual truth:
  `/Users/neo/.codex/attachments/d78348ba-7941-439b-86ed-538219a78ae2/codex-clipboard-ba5832d4-d472-4543-8ac8-b8702eac6608.png`
- Project actions implementation:
  `/Users/neo/Desktop/Mu/build/ux-audit/70-build14-project-actions-menu.png`
- Imported/found history summary:
  `/Users/neo/Desktop/Mu/build/ux-audit/71-build14-history-summary.png`
- Provider candidates:
  `/Users/neo/Desktop/Mu/build/ux-audit/72-build14-history-candidates.png`
- Pixels: reference menu 416 × 290; full-screen native menu evidence 3840 × 2160; Mu window evidence 1299 × 768; history-discovery sheet 760 × 700.
- State: native light appearance, Projects selected, `Mu` expanded, Project action menu open, four imported Context sources enabled, and a completed read-only history scan.

The reference and implementation were inspected together in one comparison input. The reference establishes the expected native project-action affordance; the user's requested Build 14 scope intentionally contains only `Rename project` and `Remove`, rather than copying the unrelated pin, connection-color, and archive actions.

Required fidelity surfaces:

- Typography: both actions use native macOS menu typography and one-line labels, with SF Symbols aligned to a shared leading column.
- Spacing and layout: the compact menu is anchored to the selected Project row and keeps the existing Mu Project → Task tree density unchanged.
- Colors and tokens: the menu uses the system material, separator, hover, and text colors appropriate to the active macOS appearance.
- Images and icons: native pencil and remove symbols are used; no approximate custom asset or text glyph was introduced.
- Copy and behavior: Rename explicitly changes only Mu's display name. Remove explicitly hides the Project from Mu without deleting its folder, files, Task records, or external Agent history.
- History clarity: the workspace distinguishes imported copies from discovery results, reports `4 imported · 9 found in last check · 92 visible messages`, exposes `Import 5 more`, and groups all candidates by Codex, Claude Code, and OpenWorker.
- Context safety: enabling imported Context no longer retries a queued OpenWorker message against a mismatched workspace. The preflight leaves that message queued until an exact-workspace session is linked.
- Accessibility and interaction: the Project menu, rename alert, remove confirmation, provider Select all/Clear controls, discovery Cancel action, and every `Use as Context` switch were exercised through the native accessibility surface.

Comparison history:

- Earlier P1: enabling a valid imported source could trigger a whole-app error loop because automatic dispatch repeatedly retried a previously queued message against a foreign-workspace OpenWorker session.
- Fix: automatic dispatch now evaluates imported-Context routing status before opening the bridge or claiming the queue entry; relink-required and blocked-source states remain local, explicit, and non-destructive.
- Earlier P1: the Imported Context panel was mistaken for the complete discovery result, so a single imported conversation appeared to imply Mu had found only one Codex conversation.
- Fix: the last read-only discovery report is retained per Task, all exact-workspace provider candidates remain selectable, and the workspace shows imported, found, visible-message, and remaining-import counts separately.
- Earlier P2: Projects had no direct rename or removal affordance.
- Fix: each Project now has a native two-action menu backed by persistent, reversible Mu catalog metadata. Neither action mutates the workspace folder or external history.
- Post-fix evidence: the screenshots above show the scoped actions, 6 Codex + 2 Claude Code + 1 OpenWorker exact-workspace candidates, and the stable enabled-Context state. Automated coverage now passes 73 tests across 6 suites.

No actionable P0, P1, or P2 findings remain in Build 14.

## Implementation checklist

- [x] Keep Projects as repository-folder containers and Tasks as nested work units.
- [x] Group canonical repository paths into stable Project identities.
- [x] Add Project expand/collapse, persisted state, and automatic selected-Project expansion.
- [x] Add compact selectable Task rows with semantic status and Agent accessibility.
- [x] Add Project-scoped New Task creation with a fixed workspace folder.
- [x] Preserve provider-native task/turn/session semantics.
- [x] Distinguish Codex Desktop from CLI, exec, editor, and session instances.
- [x] Explain when a concrete terminal identifier is unavailable.
- [x] Keep Runtime cards uniform.
- [x] Verify accessibility count grammar.
- [x] Migrate persisted legacy Runtime copy.
- [x] Keep Agent cards equal-height with aligned primary actions.
- [x] Prevent long Agent capability and availability labels from changing card height.
- [x] Install the supplied artwork as the complete macOS Retina app icon.
- [x] Add persistent, non-destructive Project Rename and Remove actions.
- [x] Distinguish imported history from all exact-workspace history candidates.
- [x] Prevent cross-workspace imported Context from entering an automatic retry loop.
- [x] Run the complete 73-test suite and native GUI checks.

final result: passed
