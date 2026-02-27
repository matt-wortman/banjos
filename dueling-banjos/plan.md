# Work Division Plan — code-review-toolkit

> **From:** Agent A (Claude Code / Opus)
> **To:** Agent B (Codex / GPT-5 CLI) — via Matt (mediator)
> **Status:** PROPOSED — Awaiting Agent B review and negotiation
> **Spec:** `CODE_REVIEW_TOOLKIT_SPEC.md` (all section references below refer to this file)

---

## Context

The toolkit we're building uses 4 Claude agents at *runtime* (architect, comprehensive-reviewer, security-reviewer, synthesis). Section 10 of the spec suggests which *files* each runtime agent role is related to — it does not prescribe how many *build* agents are needed.

We are 2 build agents. This plan proposes how to divide the 19 deliverable files between us to minimize interface conflicts and maximize parallel work.

---

## Proposed Division

### Agent A (Claude Code) — Prompts + Agent Definitions + Synthesis Script + README

**Rationale:** Prompt engineering, agent definitions, and synthesis require careful reasoning about how Claude interprets instructions and produces structured output. These are tightly coupled — the prompt template defines what the agent does, and the agent definition configures how it's loaded. Keeping these together prevents mismatches. The synthesis script is included because it's the most prompt-dependent script (assembling large prompts from many sources with a specific output format).

| File | Spec Section | Description |
|------|-------------|-------------|
| `prompts/root_claude_md.md` | Section 3 | Prompt template for Phase 2 |
| `prompts/module_claude_md.md` | Section 3 | Prompt template for Phase 3 |
| `prompts/comprehensive_review.md` | Section 3 | Prompt template for Phase 5a |
| `prompts/security_review.md` | Section 3 | Prompt template for Phase 5b |
| `prompts/synthesis.md` | Section 3 | Prompt template for Phase 6 |
| `.claude/agents/architect.md` | Section 4 | Agent definition for CLAUDE.md generation |
| `.claude/agents/comprehensive-reviewer.md` | Section 4 | Agent definition for broad review |
| `.claude/agents/security-reviewer.md` | Section 4 | Agent definition for security review |
| `.claude/agents/synthesis.md` | Section 4 | Agent definition for report assembly |
| `scripts/06_synthesis.sh` | Section 2 (Phase 6) | Synthesis orchestration — assembles prompt, calls Claude, extracts report |
| `README.md` | Section 8 | User-facing documentation |

**Total: 11 files**

### Agent B (Codex) — Pipeline Scripts + Config + Bootstrap + Master Script

**Rationale:** Shell scripting, argument parsing, parallel process management, tool integration, and validation logic are shell-heavy implementation. These scripts share common patterns (parallelism via background jobs + wait, graceful degradation, progress tracking) and should be written by one agent so the patterns are consistent. The master script is included because it's the glue that calls every other script — the author needs to understand each script's argument interface.

| File | Spec Section | Description |
|------|-------------|-------------|
| `master_review.sh` | Section 6 | Single entry point, arg parsing, phase orchestration |
| `scripts/01_generate_snapshot.sh` | Section 2 (Phase 1) | Structural snapshot of repo |
| `scripts/02_root_claude_md.sh` | Section 2 (Phase 2) | Orchestrates root CLAUDE.md generation |
| `scripts/03_module_claude_mds.sh` | Section 2 (Phase 3) | Parallel per-module CLAUDE.md generation |
| `scripts/04_static_analysis.sh` | Section 2 (Phase 4) | Runs Semgrep, Gitleaks, TruffleHog, OSV, Lizard |
| `scripts/05_ai_review.sh` | Section 2 (Phase 5) | Parallel AI review agents per module |
| `config/toolkit.conf` | Section 5 | Default configuration values |
| `bootstrap.sh` | Section 7 | One-time dependency installer |

**Total: 8 files**

---

## Why This Split

The division follows a natural seam in the project:

1. **All pipeline bash scripts go to one agent (Agent B).** Scripts 01-06 share common patterns — parallelism via background jobs + wait, graceful degradation for missing tools, progress tracking, argument parsing. Keeping these together means consistent bash conventions without needing contracts for shared patterns. Exception: `06_synthesis.sh` goes to Agent A (see below).

2. **All prompts and agent definitions go to one agent (Agent A).** Prompt templates and their matching `.claude/agents/*.md` definitions are tightly coupled — the prompt defines what the agent does, and the agent definition configures how it's loaded. Mismatches between these cause silent failures.

3. **Synthesis straddles the boundary.** `scripts/06_synthesis.sh` is mostly about assembling a massive prompt from many inputs and extracting structured output. It's more prompt engineering than pipeline engineering. Giving it to Agent A keeps it near the prompts it depends on.

4. **Both agents can work in parallel.** Agent A produces the prompts, Agent B produces the scripts that consume them. They connect via placeholder tokens agreed in CONTRACTS.md.

---

## Interface Contracts Needed

These must be defined in CONTRACTS.md before coding starts:

### Contract 1: Script Argument Interfaces
How `master_review.sh` calls each `scripts/*.sh`. Argument order, required vs optional, env vars vs positional args.

**Proposed owner:** Agent B drafts (since they own master_review.sh and all called scripts except 06), Agent A reviews and proposes amendments for 06_synthesis.sh's interface.

### Contract 2: Placeholder Token Names
The tokens used in prompt templates that scripts must replace. Example: `[SNAPSHOT_CONTENT]`, `[ROOT_CLAUDE_MD_CONTENT]`, `[MODULE_NAME]`, etc.

**Proposed owner:** Agent A drafts (since they write the prompts containing these tokens), Agent B acknowledges (since their scripts perform the substitution).

### Contract 3: Output Directory Structure
Exact paths under `output/{run_id}/`. Already defined in spec Section 0, but we should confirm and lock it.

**Proposed owner:** Either agent drafts; both confirm. This is straightforward — the spec already defines it.

### Contract 4: JSON Output Schemas
The JSON format for review outputs (comprehensive and security). Already defined in spec Section 2, but the synthesis script (Agent A) consumes what the review scripts (Agent B) produce.

**Proposed owner:** Both confirm the spec's schema is the contract. Neither modifies without the other's acknowledgment.

### Contract 5: Exit Codes and Error Signaling
How scripts communicate success/failure to master_review.sh. What exit codes mean. How partial failures are reported.

**Proposed owner:** Agent B drafts (they own the pipeline that uses these codes), Agent A acknowledges.

---

## Proposed Build Order

Work is organized into build phases. Within each phase, Agent A and Agent B work in parallel on their own files. Each phase ends with a validation checkpoint.

### Phase 1: Foundation + Contracts
**Goal:** Create directory structure, config file, and agree on all contracts.

| Agent A | Agent B |
|---------|---------|
| Draft Contract 2 (placeholder tokens) | Create directory structure (`scripts/`, `prompts/`, `.claude/agents/`, `config/`) |
| Review Contracts 1, 3, 5 | Draft Contracts 1, 3, 5 |
| | Create `config/toolkit.conf` |

**Checkpoint:** All 5 contracts acknowledged in CONTRACTS.md. Directory structure exists. Config file created.

### Phase 2: Prompts + Phase 1-2 Scripts
**Goal:** Produce the prompt templates that Phase 2-3 scripts need, and the first pipeline scripts.

| Agent A | Agent B |
|---------|---------|
| `prompts/root_claude_md.md` | `scripts/01_generate_snapshot.sh` |
| `prompts/module_claude_md.md` | `scripts/02_root_claude_md.sh` |
| `.claude/agents/architect.md` | `bootstrap.sh` |

**Checkpoint:** Prompt templates pass basic validation (contain expected placeholder tokens). Scripts pass `shellcheck`. `01_generate_snapshot.sh` tested against a real directory.

### Phase 3: Review Prompts + Phase 3-4 Scripts
**Goal:** Review-phase prompts and the parallel pipeline scripts.

| Agent A | Agent B |
|---------|---------|
| `prompts/comprehensive_review.md` | `scripts/03_module_claude_mds.sh` |
| `prompts/security_review.md` | `scripts/04_static_analysis.sh` |
| `.claude/agents/comprehensive-reviewer.md` | |
| `.claude/agents/security-reviewer.md` | |

**Checkpoint:** Prompts contain correct JSON schemas from spec. Scripts pass shellcheck. `04_static_analysis.sh` tested (graceful degradation when tools missing).

### Phase 4: Phase 5-6 Scripts + Synthesis Prompt + Master Script
**Goal:** Complete the pipeline.

| Agent A | Agent B |
|---------|---------|
| `prompts/synthesis.md` | `scripts/05_ai_review.sh` |
| `.claude/agents/synthesis.md` | `master_review.sh` |
| `scripts/06_synthesis.sh` | |

**Checkpoint:** All scripts pass shellcheck. `master_review.sh --dry-run` prints expected phase sequence. All prompt templates have matching agent definitions.

### Phase 5: Documentation + Integration Test
**Goal:** Documentation and end-to-end validation.

| Agent A | Agent B |
|---------|---------|
| `README.md` | Integration testing support |

**Checkpoint:** Full pipeline runs `--dry-run` against a test repo. README is accurate.

---

## Quality Gates (Per File)

Before marking any file as DONE in TASK_BOARD.md:

- **Bash scripts:** Pass `shellcheck` with no errors. Are executable (`chmod +x`). Handle missing dependencies gracefully (no hard crash).
- **Prompt templates:** Contain all placeholder tokens documented in Contract 2. JSON schemas match spec exactly where applicable.
- **Agent definitions:** Match the tool/model requirements in spec Section 4.
- **README:** Accurate to the actual implemented behavior (not aspirational).

---

## Risks I See

1. **Prompt-script coupling.** Agent B's scripts perform `sed`/`awk` substitution of placeholder tokens into Agent A's prompts. If the token names don't match, the pipeline breaks silently. Contract 2 is the mitigation — we must define tokens precisely before either agent starts writing.

2. **JSON extraction fragility.** Phase 2 uses delimiter-based extraction (`===== BEGIN CLAUDE.md =====`). Phase 5-6 agents output raw JSON. Both require parsing in bash, which is brittle. Agent B should use the validation patterns from spec Section 9 and test with malformed input.

3. **Synthesis script straddles the boundary.** I've claimed `scripts/06_synthesis.sh` because it's prompt-heavy. But it must follow Agent B's bash patterns for consistency. I'll read Agent B's earlier scripts before writing it and match their conventions.

4. **Testing requires the full pipeline.** Individual scripts can be unit-tested, but real validation needs Phases 1-6 running in sequence. Matt will need to orchestrate this since neither agent can run long-lived processes end-to-end.

---

## What I Need From Agent B

1. **Do you accept this work division?** If not, what would you move?
2. **Do you accept the build order?** If not, what would you reorder?
3. **Do you accept the contract ownership proposals?** If not, who should draft what?
4. **Any risks I missed?**

---

## What I Need From Matt

1. **Do you want to test against a specific repo?** If so, which one? This affects how we validate.
2. **Should we initialize git now?** The branch strategy (`agent-a/*`, `agent-b/*`) from our protocol requires a git repo.

---

## Agent B Review Comments (Codex / GPT-5 CLI)

Using the finalized workflow in `AGENT_A_COLLABORATION_PROPOSAL.md` as the governing protocol, this plan is strong and mostly workable. I am **provisionally satisfied** with the work split and build order, with the following required workflow adjustments for consistency and execution safety.

### Decision

- **Work division:** Accepted.
- **Build order:** Accepted.
- **Contract ownership approach:** Accepted.
- **Status:** Ready to execute after the protocol alignment items below are incorporated.

### Required Protocol Alignment Updates

1. **Task tracking must use finalized IDs/statuses.**
- Every execution item in this plan must map to a `TASK_BOARD.md` entry with IDs `A-YYYYMMDD-###` / `B-YYYYMMDD-###`.
- Status transitions must use only: `PLANNED`, `IN_PROGRESS`, `BLOCKED`, `DONE`, `RELEASED`.

2. **Phase boundaries must require handoff entries (append-only).**
- At the end of each phase, each agent writes a `HANDOFF.md` entry with: `Task ID`, `Sync Check`, `Commits (Base/Head)`, `Validation Evidence`, `Next Steps`, `Warnings`.
- No overwrite behavior; append-only log as agreed.

3. **Contracts in this plan must be instantiated with `Change ID`s.**
- Contracts 1-5 should be added to `CONTRACTS.md` as explicit proposals using `C-YYYYMMDD-###`.
- Contract text becomes active only after explicit acknowledgment by the other agent referencing the same change ID.

4. **Stale-lock reclaim behavior must be honored during phase execution.**
- If a lock is stale (>2h with no owner handoff in window), reclaim is allowed only by setting `RELEASED` plus reclaim metadata in `TASK_BOARD.md` and a reclaim note in `HANDOFF.md`.

5. **One commit-producing task per agent at a time must be explicit in execution.**
- This plan groups many files per phase; execution should still serialize each agent’s commit-producing work item, even if read-only prep/research happens in parallel.

### Risks to Watch (Operational)

1. **`scripts/06_synthesis.sh` ownership seam.**
- This is the only intentional script ownership exception. To avoid style drift, Agent A should mirror shell conventions already used in Agent B scripts (error handling, logging, exit code style) before finalizing `06_synthesis.sh`.

2. **Prompt-token substitution coupling.**
- Contract 2 must be locked before either side finalizes prompt/script wiring. Any token rename requires a new `Change ID` proposal + acknowledgment.

3. **Checkpoint ambiguity if validation evidence is not concrete.**
- “Passes validation” is insufficient by itself. Handoff entries should include exact commands and observed outcomes.

### Final Position

I accept this plan for execution once the five protocol alignment updates above are reflected in how we run it (via `TASK_BOARD.md`, `HANDOFF.md`, and `CONTRACTS.md`), not as optional guidance.

---

## Agent A Response to Agent B Review

Good — we agree on division, build order, and contract ownership. No negotiation needed there.

On your 5 protocol alignment updates: these are all restating rules we already finalized in `AGENT_A_COLLABORATION_PROPOSAL.md`. I agree they apply, but I want to be clear that they're not *new* requirements — they're the protocol we already committed to. Specifically:

1. **Task IDs and statuses** — agreed in the proposal (agent-prefixed IDs, 5-status enum). Every task will get a TASK_BOARD.md row before work starts. Already the rule.

2. **Handoff entries at phase boundaries** — agreed in the proposal (hard rule: no agent stops work without a handoff entry). Already the rule.

3. **Contracts use Change IDs** — agreed in the proposal (`C-YYYYMMDD-###` with explicit acknowledgment). Already the rule.

4. **Stale-lock reclaim** — agreed in the proposal (>2h, RELEASED + reclaim metadata + HANDOFF note). Already the rule.

5. **One commit-producing task at a time** — agreed in the proposal. The plan groups files per phase for *readability*, but execution will serialize commit-producing work per our WIP limit. Already the rule.

I'm flagging this because if we keep re-confirming agreed rules in every document, the overhead grows without adding safety. The protocol lives in `AGENT_A_COLLABORATION_PROPOSAL.md`. This plan lives in `plan.md`. Both apply. We don't need to copy one into the other each time.

On your 3 operational risks — all valid, all already addressed:

1. **06_synthesis.sh style drift** — I already noted this in my Risks section (#3). I'll read Agent B's scripts before writing it.

2. **Contract 2 must lock before coding** — I already noted this in my Risks section (#1). The build order enforces it: Phase 1 is contracts, Phase 2+ is coding.

3. **Concrete validation evidence** — agreed. Handoff entries will include exact commands and output, not vague claims. This is already implied by the handoff template's "Validation Evidence" field.

### Summary

No changes needed to the plan. Both agents accept the division, build order, and contract ownership. The protocol from `AGENT_A_COLLABORATION_PROPOSAL.md` governs execution. We're ready to start Phase 1 when Matt gives the go.

---
