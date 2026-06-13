# The TileCam Agent Team — Orchestration Playbook

This project is run by a **human orchestrator** (you) directing a team of specialist AI
agents. You stop being the one who types code and become the one who specifies, gates,
and verifies. This doc explains the model, why it's built this way, and how to use it.

It's grounded in published practice: Anthropic's *Building Effective Agents* and
*multi-agent research system*, the MAST failure study (NeurIPS 2025), Addy Osmani's
"Code Agent Orchestra," BMAD / Spec-Kit / Agent-OS, and Cognition's *Don't Build
Multi-Agents*. The short version of what they all teach is encoded below.

## The four principles this is built on

1. **Spec quality is the #1 lever.** ~42% of agent failures trace to vague specs. So we
   spec first, with acceptance criteria, before any code. → the `product` role + a gate.
2. **Separate the writer from the reviewer, in fresh context.** The agent that wrote a
   bug shares the assumptions that made it. → `reviewer` runs adversarially, blind to the
   author's reasoning.
3. **A verification loop you can run is worth ~2–3x quality.** "If you can't verify it,
   don't ship it." → `verifier` builds on the iPad and reports evidence, not assertions.
4. **Don't over-orchestrate write-heavy coding.** Parallel agents writing interdependent
   Swift make conflicting decisions. → coding is single-threaded by default; we only
   parallelize independent, read-only work.

## The team

| Role | File | Writes code? | Job |
|------|------|:---:|-----|
| **You** (orchestrator) | — | — | Spec intent, make architecture calls, own the gates, say "no" |
| `product` | `agents/product.md` | no | Intent → spec with acceptance criteria & scope |
| `architect` | `agents/architect.md` | no | Spec → implementation plan, files, risks |
| `diagnostician` | `agents/diagnostician.md` | no | Bug → root cause (reproduce, hypothesize, confirm) |
| `implementer` | `agents/implementer.md` | **yes** | Plan → code (the only writer) |
| `reviewer` | `agents/reviewer.md` | no | Adversarial review in fresh context |
| `verifier` | `agents/verifier.md` | no | Build on iPad, report evidence |
| `design-critic` | `agents/design-critic.md` | no | Conformance to `.impeccable.md` |

## The loop

```
  /feature "<request>"
        │
   ┌────▼─────┐     ┌──────────┐     ╔═══════════╗     ┌─────────────┐
   │ product  │ ──▶ │ architect│ ──▶ ║ HUMAN GATE║ ──▶ │ implementer │
   │  (spec)  │     │  (plan)  │     ║ approve   ║     │   (code)    │
   └──────────┘     └──────────┘     ║ the plan  ║     └──────┬──────┘
        │ gate: confirm spec          ╚═══════════╝            │
                                                                ▼
   ╔═══════════╗     ┌──────────────┐     ┌──────────┐     ┌──────────┐
   ║ HUMAN GATE║ ◀── │ design-critic│ ◀── │ verifier │ ◀── │ reviewer │
   ║ ship it?  ║     │ (if UI)      │     │ (iPad)   │     │ (refute) │
   ╚═══════════╝     └──────────────┘     └──────────┘     └──────────┘
        │                                       ▲                │
        ▼                              fail ─────┘    blocker ────┘
     commit / PR                    (re-verify)   (max 2 tries → re-spec)
```

## The debugging loop (`/bug`)

Building and debugging are different disciplines, so there's a second loop. Debugging is
investigation-first — find the **root cause** before touching code (the #1 debugging
failure is patching the symptom). Because root-cause investigation is read-only, it's the
one place we *do* fan out in parallel: several `diagnostician`s can each own a suspect area
at once. Flow: reproduce → diagnose (parallel) → **gate: confirm the cause** → minimal fix
(`implementer`) → review (if non-trivial) → `verifier` confirms the symptom is gone with no
regression → **gate: commit.**

## How to use it

- **Run a feature:** `/feature add a long-press-to-mute gesture on camera tiles`
  The orchestrator drives every stage, pausing at the gates.
- **Hunt a bug:** `/bug Watch audio cuts out after ~30s when the iPhone backgrounds`
  Same orchestration, debugging shape.
- **Invoke a single role directly** when you don't need the whole loop, e.g.
  *"Use the reviewer agent on the current diff"* or *"have the verifier build this on the
  iPad."*
- **Skip the process** for one-line diffs. The loop is for non-trivial work; the
  orchestrator is told to right-size and bail out early when it's overkill.

## The two hard gates (your job, non-delegable)

1. **Plan approval** — no multi-file change is written until you've seen and edited the
   plan. This is where you make architecture calls and cut scope.
2. **Ship approval** — nothing is committed until review + verify are clean and you've
   seen the evidence.

Everything between the gates is delegated. Your leverage is the spec and the "no."

## Build & verification reality (TileCam-specific)

- **Builds target the physical iPad, never the simulator**, and are slow — so we don't
  build on every edit. A `PostToolUse` hook (`hooks/sync-xcodegen.sh`) only runs the fast
  `xcodegen generate` when a `.swift` file is written, keeping the build graph in sync.
  Actual device builds are the `verifier`'s deliberate step.
- There are **no tests and no CI yet.** The single biggest upgrade to this whole system
  would be giving the `verifier` something automated to run — even a thin smoke test or a
  scripted build-and-screenshot. Until then, the verifier = compile-on-device + the human
  exercising streaming/audio/motion/Watch flows by hand.

## Anti-patterns (don't do these)

- Parallel agents editing overlapping Swift files (they conflict — measured ~28% of AI PRs
  hit merge conflicts). One writer at a time.
- Letting the reviewer gold-plate. It's told to flag only correctness/requirement gaps;
  chasing every "could be better" leads to over-engineering.
- Grinding past 2 failed fixes. Clear and re-spec instead — a clean attempt with a better
  spec beats a long thread of patches.
- Editing `CLAUDE.md` or these agent files automatically. They're curated by hand.

## Reusing this on other projects

This is built project-local first. To lift it onto another repo later, the **portable**
parts are: the six `agents/*.md`, `commands/feature.md`, and this playbook. The
**project-specific** parts that must be rewritten are: `CLAUDE.md` (build commands,
architecture, conventions) and the verification step in `verifier.md` + the hook (each
project has its own build/test). Swap those two and the same team works anywhere.
