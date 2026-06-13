---
description: Track down and fix a bug — reproduce, diagnose root cause (parallel read-only investigation), confirm, minimal fix, verify it's actually gone.
---

# /bug — orchestrated debugging loop

You are the **orchestrator**. The human reported a bug:

> $ARGUMENTS

Debugging is investigation-first, not construction-first. Find the *root cause* before
touching code — the most common debugging failure is patching the symptom. Delegate each
stage; subagents can't spawn subagents, so you coordinate from the top.

## The loop

1. **Capture the report.** Pin down the symptom with the human: what's observed vs.
   expected, on iPhone or Watch, steps to reproduce, when it started. If the report is
   vague, ask — you can't fix what you can't characterize. Don't guess the repro.

2. **Diagnose** — delegate to `diagnostician` (read-only). For a bug with several plausible
   areas, **fan out multiple diagnosticians in parallel**, each owning one suspect
   (e.g. one on the WebRTC path, one on Watch-sync, one on audio session) — this is safe
   because they only read. Collect their root-cause candidates with evidence.
   - If candidates conflict or confidence is low, run a second adversarial pass: have a
     diagnostician try to *disprove* the leading hypothesis.

3. **Confirm the diagnosis** —
   → **GATE:** present the root cause, evidence, and confidence to the human. If
   confidence is low and only a runtime observation can settle it, say what's needed
   (a log, a device repro) rather than fixing blind. Agree on the cause before fixing.

4. **Fix** — delegate to `implementer` with the confirmed root cause and suggested
   direction. The fix targets the **cause, minimally** — no opportunistic refactors, no
   fixing the symptom. Smallest diff that removes the cause.

5. **Review** — if the fix is non-trivial, delegate to `reviewer` (fresh context) to check
   the fix is correct and doesn't introduce a regression.

6. **Verify it's actually gone** — delegate to `verifier`: build on the iPad and confirm
   the original symptom no longer reproduces, AND that the fixed flow's neighbours still
   work (no regression). Report evidence. Some bugs (streaming/audio/motion/Watch) need a
   human device repro to truly confirm — say so explicitly.

7. **Close out** —
   → **GATE:** summarize root cause, the fix, and verification evidence. Commit only when
   the human confirms the bug is dead.

## Rules

- **Reproduce/confirm before and after.** If you can't confirm the bug exists, you can't
  confirm it's fixed.
- **Root cause, not symptom.** If the "fix" doesn't connect to a confirmed cause, stop.
- **Stop rule:** after 2 failed fix attempts, the diagnosis is probably wrong — go back to
  step 2, don't keep patching.
- Investigation parallelizes (read-only); the fix stays single-threaded.
