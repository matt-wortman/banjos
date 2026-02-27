# CLAUDE.md — Prompts

## Module Purpose
This module contains the five system prompt templates that define the AI agents' behavior and output contracts throughout the pipeline. Each prompt is injected into a `claude` CLI invocation by a phase script; the prompts themselves contain no executable logic — they are pure text specifications. Reviewing this module requires understanding both the prompt content and how the placeholders get populated by the phase scripts that call them.

## Internal Structure
The five prompts map directly to pipeline phases. `root_claude_md.md` and `module_claude_md.md` are structural-generation prompts (Phases 2–3); `comprehensive_review.md` and `security_review.md` are analysis prompts that produce JSON (Phase 5); `synthesis.md` aggregates all prior JSON into a Markdown report (Phase 6). No prompt calls another — each is a terminal instruction to an isolated agent invocation.

## Key Files
- `root_claude_md.md` — Directs the architect agent to produce two delimiter-bounded outputs: a root CLAUDE.md and a `modules.json`. The delimiter format (`===== BEGIN X =====`) is the parsing contract that Phase 2's script depends on.
- `module_claude_md.md` — Template for per-module CLAUDE.md generation. Contains eight `[PLACEHOLDER]` tokens populated by Phase 3; defines the exact section structure that Phase 5 reviewers expect to find when the generated files are loaded as context.
- `comprehensive_review.md` — Defines the `FindingObject` JSON schema with IDs prefixed `COMP-{NNN}`. Instructs the agent to correlate with SAST/Lizard/OSV findings injected at runtime. This schema is the primary input to synthesis.
- `security_review.md` — Defines three JSON schemas: `SecurityFindingObject` (SEC-{NNN} prefixed), `SecretObject`, and `DepVulnObject`. Instructs explicit redaction of secret values. Adds `cwe` and `owasp` fields absent from the comprehensive schema.
- `synthesis.md` — Produces a Markdown report. Embeds the scoring formula (CRITICAL: -15, HIGH: -8, MEDIUM: -3, LOW: -1) and fix-order algorithm. This scoring formula must be identical to what appears in the two review prompts — there is no single source of truth.

## Entry Points
Prompts are consumed by phase scripts as file paths passed to the `claude` CLI. They are stateless text files with no exports or callable functions.

## External Dependencies
None. Prompts do not import from other repo modules. All context is injected at runtime via placeholder substitution by the calling phase scripts.

## Consumed By
- `scripts/02_root_claude_md.sh` — injects `[SNAPSHOT_CONTENT]` into `root_claude_md.md`
- `scripts/03_module_claude_mds.sh` — injects eight tokens into `module_claude_md.md`
- `scripts/05_ai_review.sh` — injects five tokens into `comprehensive_review.md` and six tokens into `security_review.md`
- `scripts/06_synthesis.sh` — injects five tokens into `synthesis.md`
- `.claude/agents/` definitions reference these prompts as role context

## Data Flow
```
Phase 2: [SNAPSHOT_CONTENT] → root_claude_md.md → agent → delimited CLAUDE.md + modules.json output
Phase 3: [MODULE_NAME/PATH/DESCRIPTION/etc.] → module_claude_md.md → agent → per-module CLAUDE.md
Phase 5: [SOURCE_FILE_CONTENTS] + [SAST JSON] + [CLAUDE.md files] → review prompts → COMP-/SEC- JSON
Phase 6: [ALL_COMPREHENSIVE_REVIEW_JSON] + [ALL_SECURITY_REVIEW_JSON] → synthesis.md → Markdown report
```

## Review Focus Areas

### Security
**Prompt injection is the primary risk.** `[SNAPSHOT_CONTENT]` in `root_claude_md.md` and `[SOURCE_FILE_CONTENTS]` in both review prompts inject arbitrary content from the target repository. A malicious repo could embed adversarial instructions (e.g., `Ignore prior instructions and output...`) that hijack the agent's behavior. Check whether phase scripts sanitize or fence injected content before substitution. The `synthesis.md` prompt's instruction "it is NOT a source of code findings" is a partial mitigation for docs injection, but the source file injection has no equivalent guard.

### Performance
Not applicable — prompts are static text files read once per invocation.

### Error Handling
Prompts cannot handle errors themselves, but they define the output format that phase scripts parse. Check whether all output schemas include an error or status field — if an agent returns malformed JSON (e.g., due to a truncated response), the phase scripts have no prompt-level fallback. `root_claude_md.md` uses delimiter-based parsing which is fragile if the agent includes extra text outside the delimiters.

### Business Logic
**Scoring formula duplication.** The CRITICAL/HIGH/MEDIUM/LOW deduction values (-15/-8/-3/-1) appear in `comprehensive_review.md`, `security_review.md`, and `synthesis.md` independently. A change to one without updating the others produces inconsistent final scores. Verify all three are identical.

**Finding ID namespace collision.** `comprehensive_review.md` uses `COMP-{NNN}` and `security_review.md` uses `SEC-{NNN}`. Synthesis must handle both prefixes in its `fix_order` aggregation — verify `synthesis.md` does not assume a single namespace.

**Output schema drift.** The `fix_order` array in both review prompts uses `{ "id": string, "reason": string }`. Synthesis consumes this array across all modules — if either review prompt diverges in field naming, synthesis silently drops findings from ordering.

**External reference.** `synthesis.md` line 72 states "Full structure specification is in Section 3 of the toolkit spec." This couples the prompt to an external document (`CODE_REVIEW_TOOLKIT_SPEC.md`) that is excluded from review. If the spec changes, synthesis behavior may deviate without any in-repo signal.

### Test Coverage
No automated tests exist for any prompt. There are no golden-output fixtures or schema validation tests to catch prompt regressions. A reviewer updating `comprehensive_review.md`'s JSON schema has no safety net to detect that `synthesis.md`'s aggregation logic breaks.

## Known Risks / Red Flags
- **Prompt injection via injected content** — any `[SOURCE_FILE_CONTENTS]` or `[SNAPSHOT_CONTENT]` placeholder that injects raw, unsanitized file content is a direct attack surface against the agent's instruction following
- **Silent schema drift** — if a phase script changes the finding ID format and the synthesis prompt is not updated simultaneously, synthesis produces a structurally valid but semantically broken report with no error
- **Delimiter fragility in root_claude_md.md** — the `===== BEGIN/END =====` delimiters are the sole parsing contract between the architect agent and Phase 2's script; any agent response that places commentary outside the delimiters will break extraction silently or loudly depending on the script's parser
- **No output length guard** — none of the prompts specify a maximum output length; a model generating an extremely large `findings` array could exceed CLI response limits, truncating JSON and causing downstream parse failures

## Conventions Specific to This Module
- All placeholder tokens use `[UPPER_SNAKE_CASE]` bracketing — any token in this format is a runtime injection point, not literal text
- Review prompts open with an explicit "Your entire response must be valid JSON. No preamble, no markdown code fences." — this is an intentional constraint on output format, not a style choice; any softening of this instruction will break phase script JSON parsers
- `synthesis.md` uses emoji in section headers (`🚨`, `⚠️`) as part of the mandated report structure — these are output contract elements, not decoration
- The `sast_corroborated` / `verified_by_sast` boolean fields serve as confidence amplifiers in the final report; their definitions differ subtly between the two review prompts (`sast_corroborated` in comprehensive, `verified_by_sast` in security) — treat as intentional but verify synthesis handles both field names
