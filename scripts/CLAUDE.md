# CLAUDE.md — Pipeline Scripts

## Module Purpose
Six numbered bash scripts implementing the core pipeline of the toolkit. Each script owns one phase: snapshot capture (01), root CLAUDE.md + modules.json generation (02), per-module CLAUDE.md generation (03), static analysis (04), AI-driven review (05), and final report synthesis (06). Scripts execute in strict sequence via `master_review.sh`; each receives positional arguments for its inputs and writes artifacts to caller-provided output paths. No script invokes another — all coordination happens in the orchestrator.

## Internal Structure
Each script is self-contained: argument parsing → input validation → tool availability checks → work → artifact validation → exit. Phases 03 and 05 spawn background workers up to `PARALLEL_LIMIT` using `&` with a `jobs -pr | wc -l` polling loop. Phase 04 runs all five tool functions in parallel unconditionally. Phases 02, 03, and 05 share an identical `strip_outer_code_fence_if_present` helper (copy-pasted, not shared). Phases 03 and 05 use a two-attempt retry loop with an appended `retry_note` on the second attempt.

## Key Files
- `01_generate_snapshot.sh` — Walks the target repo with `find`/`tree`, emitting a structured snapshot file; the sole source of truth for Phase 2
- `02_root_claude_md.sh` — Invokes `claude` once to produce both `CLAUDE.md` and `modules.json` from delimited output blocks; validates both before writing to `$REPO_PATH`
- `03_module_claude_mds.sh` — Reads `modules.json`, spawns one Claude invocation per module in parallel, validates heading + minimum line count, writes `CLAUDE.md` into each module directory inside `$REPO_PATH`
- `04_static_analysis.sh` — Runs semgrep, gitleaks, trufflehog, osv-scanner (with npm/pip fallback), and lizard in parallel; tool absence or failure writes a structured error/skipped JSON rather than aborting
- `05_ai_review.sh` — Per module, spawns two parallel workers (comprehensive + security), assembles prompts with static findings filtered per module path and prioritized source file contents, validates output against strict jq schemas
- `06_synthesis.sh` — Aggregates all review JSONs, collects tiered documentation, substitutes into the synthesis prompt, invokes Claude once, and deterministically computes `report_data.json` from review scores (not from Claude output)

## Entry Points
All scripts are invoked exclusively by `master_review.sh` via its `run_cmd` wrapper. No script is designed for direct end-user invocation, though each validates its positional arguments and can be run standalone for debugging.

Signatures:
- `01_generate_snapshot.sh <repo_path> <snapshot_output_path>`
- `02_root_claude_md.sh <repo_path> <snapshot_input_path> <model_default>`
- `03_module_claude_mds.sh <repo_path> <model_default> <parallel_limit>`
- `04_static_analysis.sh <repo_path> <static_output_dir> <skip_static> <skip_secrets>`
- `05_ai_review.sh <repo_path> <static_dir> <reviews_dir> <model_default> <model_security> <parallel_limit>`
- `06_synthesis.sh <repo_path> <reviews_dir> <report_path_md> <model_synthesis> <docs_limit_lines> [previous_report_path]`

## External Dependencies
- `config/toolkit.conf` — Indirectly consumed: all parameter values arrive as positional args set by `master_review.sh` from config
- `prompts/root_claude_md.md` — Required by Phase 2; must contain `[SNAPSHOT_CONTENT]`
- `prompts/module_claude_md.md` — Required by Phase 3; must contain eight specific tokens
- `prompts/comprehensive_review.md`, `prompts/security_review.md` — Required by Phase 5; token presence validated at startup
- `prompts/synthesis.md` — Required by Phase 6
- `$REPO_PATH/modules.json` — Written by Phase 2, read by Phases 3 and 5; each consumer re-validates the schema independently
- `$REPO_PATH/CLAUDE.md` — Written by Phase 2, read by Phases 3, 5, and 6

## Consumed By
`master_review.sh` — the sole caller; invokes scripts positionally as `scripts/01_...sh` through `scripts/06_...sh`

## Data Flow
```
01: repo_path + snapshot_output_path
    → find/tree walk (excludes .git, node_modules, dist, etc.)
    → structured snapshot file (directory tree, manifests, lock files, config paths, extension summary)

02: repo_path + snapshot_file + model
    → claude -p assembled_prompt → phase2_raw.txt
    → extract_delimited_block (===== BEGIN CLAUDE.md =====, ===== BEGIN modules.json =====)
    → strip_outer_code_fence + validate heading + validate jq schema
    → $REPO_PATH/CLAUDE.md, $REPO_PATH/modules.json

03: repo_path + model + parallel_limit
    → read modules.json review_order[]
    → per module: assemble prompt (8 tokens) → claude → strip fence → normalize heading → line count check
    → $REPO_PATH/<module_path>/CLAUDE.md (or $REPO_PATH/CLAUDE.md for root module)
    → .claude_review_progress (flock-protected append)

04: repo_path + static_output_dir + skip_static + skip_secrets
    → 5 parallel tool workers: semgrep, gitleaks, trufflehog, osv-scanner, lizard
    → each writes JSON artifact or {"skipped":true} / {"error":"..."} fallback
    → ensure_expected_artifacts validates all 5 exist and are valid JSON

05: repo_path + static_dir + reviews_dir + model_default + model_security + parallel_limit
    → read modules.json review_order[]
    → per module × 2 review types:
        filter_static_findings_json (path-scoped per module)
        read_module_source_contents (priority-sorted, token-budget capped at MAX_SOURCE_CHARS)
        assemble prompt → claude → normalize_json_response → validate schema
        fallback: write error JSON (never fails the module)
    → reviews/comprehensive_<id>_<name>.json, reviews/security_<id>_<name>.json

06: repo_path + reviews_dir + report_path_md + model_synthesis + docs_limit_lines [+ previous_report]
    → collect all comprehensive_*.json + security_*.json
    → collect tiered docs (README priority-1 capped 500 lines, others capped at DOCS_LIMIT_LINES)
    → optional previous report summarized via jq
    → claude -p assembled_prompt → $REPORT_PATH_MD
    → deterministic report_data.json computed from review scores (weighted by estimated_file_count)
```

## Review Focus Areas

### Security
- `--dangerously-skip-permissions` is passed to every `claude` invocation in phases 02, 03, and 05 — the AI agent runs with no tool restrictions; verify this is acceptable in your threat model
- Phases 02, 03, and 05 assemble prompts via Bash `${var//[TOKEN]/$value}` string substitution where `$value` is verbatim file content from the target repo — a file containing `===== BEGIN CLAUDE.md =====` or prompt injection instructions will corrupt the assembled prompt or forge output blocks
- Phase 02's `extract_delimited_block` trusts the first occurrence of the exact marker string — a target repo file whose content includes these markers could produce a forged `CLAUDE.md` or `modules.json`
- Phase 05's `filter_static_findings_json` uses string prefix matching (`startswith($mp + "/")`) — a module at path `src` will match files under `src-legacy/`
- Phase 03's `file_listing` is built with `find "$module_path"` inside a subshell after `cd "$REPO_PATH"` — if `module_path` contains spaces and the surrounding code doesn't quote it, path splitting could occur; verify all uses of `$module_path` in prompt assembly are quoted
- Gitleaks and TruffleHog are skipped when `SKIP_SECRETS=true` but Semgrep's `p/secrets` config is also omitted — verify the skip semantics are consistent with the caller's intent

### Performance
- Phase 03 and 05 use `while [[ "$(jobs -pr | wc -l ...)" -ge "$PARALLEL_LIMIT" ]]; do sleep 1; done` — this spawns a subshell on every 1-second tick per throttle check; for large repos with many modules this creates sustained process churn
- Phase 05's `read_module_source_contents` accumulates `source_blob` via string concatenation (`source_blob+="$block"`) — for large modules this copies the entire accumulated string on each append; bash string growth is O(n²)
- Phase 06 loads all review JSONs into memory via `jq -s '.' "${COMP_FILES[@]}"` in a single call — with many large modules this can produce a very large in-memory JSON document
- Phase 05 runs `filter_static_findings_json` four times per module (semgrep, gitleaks, trufflehog, lizard), each spawning a `jq` subshell — for repos with many modules the total `jq` invocation count is 4 × N × 2 review types

### Error Handling
- All scripts use `set -euo pipefail`, but phase 04's tool runner functions use `return 0` after writing error JSON — a tool that exits non-zero is silently converted to a structured error artifact; upstream callers see success even when all five tools failed
- Phase 05's `run_review_worker` always returns 0 after both attempts (via `write_invalid_json_fallback`) — a broken review is indistinguishable from a legitimate one until downstream schema inspection
- Phase 06 has no retry — a single Claude API failure for synthesis aborts the entire phase with no recovery path and leaves `$RAW_OUTPUT_PATH` empty
- No `trap` cleanup handlers in phases 03, 04, or 05 — if the script is killed mid-run, background worker temp files (`mktemp`) will leak in `/tmp`
- Phase 02 has a `trap 'rm -f "$tmp_claude" "$tmp_modules"' EXIT` but this fires on any exit including failure, correctly cleaning up; the other phases do not replicate this

### Business Logic
- Phases 02 and 03 write artifacts directly into `$REPO_PATH` (CLAUDE.md, modules.json, per-module CLAUDE.md files) — these files are created in the target repository under review, not in the isolated output directory; a failed mid-run pipeline leaves the target repo in a partially modified state
- Phase 03 tracks progress in `$REPO_PATH/.claude_review_progress` — this file is truncated (`> "$PROGRESS_PATH"`) at the start of every Phase 3 run, meaning `--resume` has no effect for Phase 3; it always re-runs all modules regardless of prior completion
- Phase 05's `osv_json` is read from the whole-repo OSV artifact and is NOT filtered per module — every module's security review receives the full repo's dependency vulnerability list
- Phase 06's weighted score uses `estimated_file_count` from `modules.json` (defaulting to 1 if absent) — this field is AI-generated in Phase 2 and may not accurately reflect actual file counts, skewing the overall score
- `review_order` in modules.json is intended to define processing order, but phases 03 and 05 background all workers immediately — the array order only affects the sequence in which jobs are submitted to the OS scheduler, not actual completion order

### Test Coverage
- No tests exist for any of the six scripts
- `strip_outer_code_fence_if_present` is copy-pasted across scripts 02, 03, and 05 — any bug fix must be applied in three places; untested edge cases include files that are a single line, files with only backtick fences and no content, and fence lines with trailing whitespace
- `filter_static_findings_json` handles six distinct JSON structural shapes (array, `.results`, `.findings`, `.issues`, `.runs[].results`, passthrough for skipped/error) with no tests; the path normalization logic (`gsub("\\\\"; "/")`, `sub("^\\./"; "")`) is particularly fragile
- `validate_comprehensive_json` and `validate_security_json` are 40-line jq expressions — no tests for the boundary conditions (scores outside range, missing optional fields, empty findings arrays)
- The two-attempt retry path in phases 03 and 05 (the second attempt with `retry_note`) is entirely untested
- Phase 06 deterministic scoring (`jq -n` weighted average) has no tests; the `// 1` default for missing `estimated_file_count` and `if ... has("error") then 0` fallback behavior are unverified

## Known Risks / Red Flags
- **Target repo mutation** — Phases 02 and 03 write generated files directly into `$REPO_PATH`; if the pipeline is interrupted, the target repository is left with partially generated AI-authored CLAUDE.md files that may contain incomplete or hallucinated content
- **Prompt injection via repo content** — All assembled prompts embed raw file contents with no sanitization; a target file containing the exact delimiter strings used in Phase 02 (`===== BEGIN CLAUDE.md =====`) or containing adversarial instructions will corrupt or hijack AI output
- **Silent review failures** — Phase 05 never propagates worker failure; modules where both Claude attempts produce invalid JSON get an `{"error":"agent_output_invalid_json"}` artifact that scores 0 in Phase 06, but no stderr warning surfaces to the operator
- **`strip_outer_code_fence_if_present` triplication** — Divergence between the three copies is a latent bug source; any fix to the `awk` logic must be applied identically in all three scripts (02, 03, 05)

## Conventions Specific to This Module
- `SCRIPT_DIR` is resolved via `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` in every script; `TOOLKIT_ROOT` is derived from `$SCRIPT_DIR/..` — replicate this pattern for any new scripts
- Tool binary names in Phase 04 are overridable via environment variables (`SEMGREP_BIN`, `GITLEAKS_BIN`, etc.) defaulting to the bare binary name — this pattern enables testing with stubs
- Missing or unavailable tools always produce a valid `{"skipped":true,"reason":"..."}` JSON artifact rather than empty files or hard failures — downstream consumers must check for this shape before interpreting findings
- Prompt token substitution uses the Bash `${var//[TOKEN]/$value}` form throughout — tokens are bracketed uppercase identifiers; maintain this convention for any new prompt placeholders
- Phase completion always emits `echo "Phase N complete: ..."` to stdout as a canonical progress signal — do not suppress this in wrappers
- Error artifacts use the shapes `{"skipped":true,"reason":"<string>"}` and `{"error":"<string>","tool":"<string>"}` — these two shapes are the only acceptable fallbacks; never write empty files or non-JSON content as phase output
