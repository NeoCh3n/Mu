# Runtime Control Plane Transfer Manifest

## Scope

- Source task: `019f9e77-17bb-7903-9f84-6af68c3bb00c`
- Destination: `/Users/neo/Desktop/Mu/runtime-control-plane-transfer/`
- Transfer method: four Base64 payloads, concatenated strictly in the order `1 → 2 → 3 → 4`
- Content policy: source documents and Mermaid definitions were preserved; no product content, labels, nodes, or diagram structure were redesigned

## Conversation archive

- File: `CONVERSATION.md`
- Source pagination completed with `hasMore=false`
- Pages/turns archived: 20
- Order: chronological
- Included: all user messages, all assistant final answers, and all assistant commentary messages returned by `read_thread`
- Excluded: private reasoning summaries and mechanical tool/file-change records
- Last user request in the source archive: `将这个对话及全部内容全部转移到 projects mu中。`

## Bundle integrity

- Part character lengths: `16000`, `16000`, `16000`, `480`
- Combined Base64 length: `48480` characters, plus one file-ending newline
- Decoded archive size: `36359` bytes
- Expected SHA-256: `1b3576391cabd9e51da643877ceedac54f7d97cd5fca38b86f13176481109930`
- Actual SHA-256: `1b3576391cabd9e51da643877ceedac54f7d97cd5fca38b86f13176481109930`
- Result: exact match

All eight archive entries were compared byte-for-byte by SHA-256 against their extracted copies and matched:

1. `outputs/five-handoff-validation-template.md`
2. `outputs/runtime-control-plane-design-review.md`
3. `outputs/workbuddy-adapter-capability-probe.md`
4. `outputs/runtime-control-plane-architecture.mmd`
5. `outputs/runtime-control-plane-lifecycles.mmd`
6. `outputs/runtime-control-plane-review-lifecycle.mmd`
7. `outputs/runtime-layer-comparison.mmd`
8. `work/office-hours-cold-read.txt`

## Diagram exports

The four transferred Mermaid sources were rendered locally with Mermaid CLI `11.12.0` and the installed Chrome browser:

| Mermaid source | SVG | PNG |
|---|---|---|
| `runtime-control-plane-architecture.mmd` | generated | generated at 2× |
| `runtime-control-plane-lifecycles.mmd` | generated | generated at 2× |
| `runtime-control-plane-review-lifecycle.mmd` | generated | generated at 2× |
| `runtime-layer-comparison.mmd` | generated | generated at 2× |

All eight rendered files are non-empty. The PNGs were visually inspected for renderer errors and clipping.

### Editable Excalidraw export limitation

No `.excalidraw` file was emitted. The official Mermaid-to-Excalidraw converter was attempted locally, but its Node path failed on a DOM sanitizer incompatibility (`DOMPurify.addHook is not a function`), while the browser-bundling fallback was blocked by ignored native build scripts. In addition, the converter officially targets Mermaid flowchart and sequence diagrams, while two transferred sources use `stateDiagram-v2`.

Per the transfer instruction, the canonical `.mmd` sources were preserved unchanged and no hand-rebuilt or approximate Excalidraw substitute was created.

## Final inventory

- 1 chronological conversation archive
- 1 transfer manifest
- 1 SHA-256 checksum file
- 6 retained bundle/provenance files
- 8 extracted source files
- 8 generated diagram exports: 4 SVG and 4 PNG
- Total durable files after checksums are written: 25

`SHA256SUMS` records the integrity of every durable file except itself.
