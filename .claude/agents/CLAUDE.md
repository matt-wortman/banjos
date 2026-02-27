# CLAUDE.md — Agent Definitions

## Module Purpose
This module contains the four Claude sub-agent definitions that give each AI participant in the pipeline its role, tool permissions, and behavioral constraints. These markdown files with YAML front matter are passed directly to the `claude` CLI at invocation time. Understanding these definitions is prerequisite to reviewing the Phase 2, 5, and 6 scripts that invoke them, because the scripts' correctness depends on the agents producing output that matches the expected contracts.

## Internal Structure
Each file is a self-contained agent definition: YAML front matter declares `name`, `description`, `tools`, and `model`; the body is a freeform system prompt that constrains agent behavior. There is no cross-agent calling — agents are isolated and invoked independently by phase scripts. Two agents (`comprehensive-reviewer`, `security-reviewer`) run in parallel per module in Phase 5; the remaining two are singletons per pipeline run.

## Key Files
- `architect.md` — Phase 2 agent; granted `Read`, `Write`, `Bash` to analyze repo snapshot and produce `root CLAUDE.md` + `modules.json`; uses Sonnet
- `comprehensive-reviewer.md` — Phase 5 agent; `Read`-only; produces structured JSON quality findings for one module; uses Sonnet
- `security-reviewer.md` — Phase 5 agent; `Read`-only; produces structured JSON security findings using OWASP/CWE taxonomy; uses Opus for accuracy
- `synthesis.md` — Phase 6 agent; `Read` + `Write`; aggregates all review JSON, computes scores, produces the final Markdown report; uses Opus
- `CLAUDE.md` — This file

## Entry Points
Agents have no self-invocation. They are externally instantiated by:
- `scripts/02_root_claude_md.sh` → `architect`
- `scripts/05_ai_review.sh` → `comprehensive-reviewer` and `security-reviewer` (once per module)
- `scripts/06_synthesis.sh` → `synthesis`

The `claude` CLI call in each script passes the agent definition file and injects the corresponding prompt from `prompts/`.

## External Dependencies
- `prompts/` — Each agent's behavior is shaped by both its system prompt (this module) and the injected content prompt at invocation time; the two must be consistent
- `output/<run_id>/` — Agents with `Write` permission target subdirectories of this path; the path is injected via the invoking script

## Consumed By
- `scripts/` — Phase scripts 02, 05, 06 pass these files to the `claude` CLI

## Data Flow
Phase script → `claude --agent architect.md --prompt <injected content>` → agent reads snapshot/modules → agent writes CLAUDE.md + modules.json to `output/<run_id>/`

Phase script → `claude --agent comprehensive-reviewer.md` → agent reads module files → returns JSON findings on stdout → script writes to `output/<run_id>/reviews/`

Phase script → `claude --agent synthesis.md` → agent reads all review JSON → agent writes final report to `output/<run_id>/reports/`

## Review Focus Areas

### Security
- **Tool permission scope:** `architect` has `Bash` access in addition to `Read`/`Write` — verify the invoking script constrains the working directory and that no shell injection path exists from repo content into the `Bash` tool
- **`security-reviewer` SAST correlation:** The `verified_by_sast=true` field requires the agent to have visibility into Phase 4 static output; check whether the script actually passes that data or whether the field is always false
- **Secret redaction instruction:** `security-reviewer` system prompt instructs never to include actual secret values — confirm the invoking script does not pass secret-bearing context as prompt content
- **Read-only enforcement for reviewer agents:** Both `comprehensive-reviewer` and `security-reviewer` declare only `Read` — verify the CLI invocation does not override this with additional tool flags

### Performance
- `security-reviewer` and `synthesis` use Opus (`claude-opus-4-6`), which is slower and more expensive per token than Sonnet; if modules are large, latency and cost in Phase 5 may be significant
- No streaming or partial-output handling is declared; large synthesis outputs could hit CLI timeout or buffer limits

### Error Handling
- Agents are instructed to return bare JSON with no preamble or code fences; if an agent deviates (e.g., wraps output in markdown), the consuming script's JSON parsing will silently fail or produce corrupt review data
- No retry or fallback behavior is declared in any agent definition; error handling must live entirely in the invoking phase scripts

### Business Logic
- **Output contract alignment:** `comprehensive-reviewer` and `security-reviewer` both promise "valid JSON that exactly matches the schema in the prompt" — if `prompts/comprehensive_review.md` or `prompts/security_review.md` defines a schema that diverges from what `synthesis` expects, findings will be lost or misaggregated silently
- **Fix-order algorithm:** `synthesis` is instructed to "account for inter-module dependencies" — this is complex logic delegated entirely to the agent; there is no deterministic fallback if the agent reasons incorrectly
- **Score formula:** `synthesis` must compute scores "EXACTLY per the formula in the prompt" — any prompt update that changes the formula must be reflected here or scores will be incorrect

### Test Coverage
- No tests exist for any agent definition; correctness is entirely implicit in the system prompt wording
- No schema validation layer catches malformed agent output before it reaches `synthesis`
- No test fixtures exist for expected JSON output shapes from reviewer agents

## Known Risks / Red Flags
- **Bash tool on untrusted content:** `architect` has `Bash` access and analyzes content from the target repository being reviewed. If the repo contains files designed to manipulate a language model into running shell commands, this is a prompt injection → RCE path. This is the highest-risk surface in the entire toolkit.
- **Silent schema drift:** Reviewer agents and the synthesis agent share a JSON schema implicitly through prompt wording. There is no enforced schema (e.g., JSON Schema validation). A prompt edit to one file can silently break the other without any error at invocation time — the failure only manifests as missing findings in the final report.
- **Model mismatch:** `architect` uses Sonnet; `security-reviewer` and `synthesis` use Opus. If `config/toolkit.conf` overrides model names, the front matter values here may be stale, creating a hidden discrepancy between documented and actual behavior.
- **No agent isolation boundary:** All agents with `Write` permission operate on the same `output/<run_id>/` tree. A misbehaving or prompt-injected agent could overwrite artifacts from a prior phase, corrupting the pipeline state without detection.

## Conventions Specific to This Module
- YAML front matter is mandatory; the `claude` CLI parses `name`, `tools`, and `model` from it — omitting or misspelling these keys silently degrades agent capability
- Body text after the front matter is the system prompt verbatim; no markdown rendering occurs at invocation time, so formatting is cosmetic only
- `tools` lists only the tools the agent is permitted to call; this is a least-privilege declaration and should not be expanded without explicit justification
- The `description` field is human-readable metadata used by the invoking script for logging, not parsed by the agent itself
