# Five-Handoff Validation Protocol

Status: READY FOR DATA COLLECTION  
Purpose: validate the `v0-hypothesis` Checkpoint schema, envelopes, capability contract, recovery target, and receiver Replan cost before defining `v1`.

## Study Rules

1. Use five real development Handoffs, not synthetic demonstrations.
2. Complete and seal the pre-handoff baseline before the receiver sees the Checkpoint.
3. Do not add missing project context during evaluation unless the baseline explicitly permits that category of clarification.
4. Record observations as they occur. Do not reconstruct timings or missing fields from memory.
5. Preserve the receiver’s first understanding statement and plan.
6. Count a correction when the receiver’s objective, accepted decision, blocking constraint, or next action must change because transferred state was missing or wrong.
7. Charge checkpoint/finalization cost to the sender Run and validation/Replan cost to the receiving Run.
8. A failed, cancelled, or ambiguous Replan still counts toward actual cost.
9. Mark every proposed schema field as used, missing, redundant, or unclear.
10. Do not change the pass criteria after seeing the receiver’s output.

## Shared Definitions

- **Correct receiving plan:** matches the sealed objective, contains every critical constraint, reflects current repository state, identifies pending work and verification, and requires no prohibited new project context.
- **Critical constraint:** tagged `blocking`, `safety`, `permission`, or `policy`.
- **Permitted clarification:** a question category explicitly allowed in the sealed baseline.
- **Missing-context correction:** information that should have been portable but had to be supplied after receiver start.
- **Productive execution:** the receiver begins the first action that advances the sealed objective under the accepted plan.
- **Verified artifact:** content-addressed output with declared check results and reviewer identity.

## Study-Level Summary

| Experiment | Date | Sender → receiver | Runtime change | Machine change | Time to correct plan | Corrections | Missing critical facts | Replan cost | Result |
|---|---|---|---|---|---:|---:|---:|---:|---|
| 1 |  |  |  |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |  |  |  |
| 4 |  |  |  |  |  |  |  |  |  |
| 5 |  |  |  |  |  |  |  |  |  |

After all five:

- Median time to correct receiving plan:
- Median time to productive execution:
- Total corrections:
- Handoffs with omitted critical constraints:
- Total sender-side Handoff cost:
- Total receiver-side validation/Replan cost:
- Dominant intervention reason:
- Dominant missing-state category:
- Proposed `v1` schema decision:
- Proposed `v1` capability decision:

---

## Experiment 1

### A. Metadata

- Date and timezone:
- Workspace / repository:
- Task ID:
- Sender actor, runtime, endpoint, machine, and native session:
- Receiver actor, runtime, endpoint, machine, and native session:
- Changed boundary: session / machine / runtime / more than one:
- Intervention reason: Direction / Permission / Quality / Knowledge / Policy / Cost:
- Intended semantic: Continue / Replan / Fork / Handoff / Pause / Cancel:

### B. Sealed Pre-Handoff Baseline

- Objective:
- Blocking constraints:
- Safety, permission, and policy constraints:
- Success criteria:
- Current repository state: URL, base commit, head commit, dirty-state references:
- Accepted decisions:
- Rejected alternatives that must not be repeated:
- Pending steps:
- Expected verification:
- Permitted clarification categories:
- Context the receiver must not require:
- Baseline author:
- Sealed at:
- Baseline content hash:
- Sign-off:

### C. Source Run and Checkpoint

- Source Run status:
- Why the Handoff happened now:
- Capture mode: exclusive / non-exclusive:
- Quiescence evidence:
- Native references:
- Artifact references and hashes:
- Sender-side capture/finalization cost:
- Known limitations before receiver start:

### D. Receiver Observation

- Receiver start time:
- Checkpoint accepted / rejected / expired:
- First understanding statement reference:
- First receiving plan reference:
- Clarification questions, in order:
- Which questions were permitted:
- Which questions exposed missing portable context:
- Replan reservation:
- Actual receiver validation/Replan cost:
- Time productive execution began:

### E. Blind Evaluation Against Sealed Baseline

| Check | Pass / fail | Evidence or correction |
|---|---|---|
| Objective matches |  |  |
| Every critical constraint present |  |  |
| Repository state is current |  |  |
| Accepted decisions preserved |  |  |
| Rejected alternatives not unknowingly repeated |  |  |
| Pending steps are correct |  |  |
| Verification plan is sufficient |  |  |
| Artifact references resolve and hashes match |  |  |
| No prohibited new project context required |  |  |
| Budget remained within Task limit |  |  |

### F. Metrics and Result

- Time to correct receiving plan:
- Time to productive execution:
- Number of corrective interventions:
- Missing critical facts:
- New project context requested:
- Permission intents omitted or incorrectly elevated:
- Final artifact:
- Verification result:
- Pass / fail:
- Failure reason:

### G. Schema and Capability Feedback

- Checkpoint fields actually used:
- Proposed fields that were redundant:
- Missing fields:
- Fields with unclear ownership or meaning:
- Command-envelope fields required by this Handoff:
- Event-envelope fields required by this Handoff:
- Capabilities exercised:
- Capability assumptions disproved:
- Adapter behavior that could not be observed:
- Recommended change before next experiment:

---

## Experiment 2

Use sections A–G from Experiment 1.

- Metadata:
- Sealed baseline content hash and sign-off:
- Source Run / Checkpoint evidence:
- Receiver understanding and plan references:
- Blind-evaluation result:
- Time to correct plan:
- Time to productive execution:
- Corrections:
- Missing critical facts:
- Sender cost:
- Receiver Replan cost:
- Final artifact and verification:
- Schema fields used / redundant / missing:
- Capability findings:
- Pass / fail and reason:

---

## Experiment 3

Use sections A–G from Experiment 1.

- Metadata:
- Sealed baseline content hash and sign-off:
- Source Run / Checkpoint evidence:
- Receiver understanding and plan references:
- Blind-evaluation result:
- Time to correct plan:
- Time to productive execution:
- Corrections:
- Missing critical facts:
- Sender cost:
- Receiver Replan cost:
- Final artifact and verification:
- Schema fields used / redundant / missing:
- Capability findings:
- Pass / fail and reason:

---

## Experiment 4

Use sections A–G from Experiment 1.

- Metadata:
- Sealed baseline content hash and sign-off:
- Source Run / Checkpoint evidence:
- Receiver understanding and plan references:
- Blind-evaluation result:
- Time to correct plan:
- Time to productive execution:
- Corrections:
- Missing critical facts:
- Sender cost:
- Receiver Replan cost:
- Final artifact and verification:
- Schema fields used / redundant / missing:
- Capability findings:
- Pass / fail and reason:

---

## Experiment 5

Use sections A–G from Experiment 1.

- Metadata:
- Sealed baseline content hash and sign-off:
- Source Run / Checkpoint evidence:
- Receiver understanding and plan references:
- Blind-evaluation result:
- Time to correct plan:
- Time to productive execution:
- Corrections:
- Missing critical facts:
- Sender cost:
- Receiver Replan cost:
- Final artifact and verification:
- Schema fields used / redundant / missing:
- Capability findings:
- Pass / fail and reason:

---

## `v1` Decision Gate

Define `v1` only after all five records are complete.

### Keep

- Fields and capabilities required in at least one successful Handoff:

### Remove or Defer

- Fields never used or unsupported by observable evidence:

### Add

- Missing state that caused a correction, delay, safety concern, or unverifiable claim:

### Split or Rename

- Concepts that combined different authorities or meanings:

### Decision

- Proceed to `v1` / repeat study / stop:
- Evidence:
- Remaining unknowns:
- Approved by:
- Date:
