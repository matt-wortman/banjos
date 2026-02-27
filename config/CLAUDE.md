# CLAUDE.md — Configuration

## Module Purpose
A single flat key-value configuration file (`toolkit.conf`) that supplies all runtime parameters to every pipeline phase. It acts as the sole source of truth for model selection, parallelism limits, token budgets, static analysis thresholds, scoring weights, tool binary paths, and reporting flags. No other module owns config values; every phase sources from here. Reviewing this file is a prerequisite to understanding any other module.

## Internal Structure
No internal hierarchy — one flat file parsed top-to-bottom by Bash `source`. Keys are grouped into seven concern blocks via inline comments: Models, Parallelism, Context limits, Static tool thresholds, Scoring, Reporting, Tool paths. No functions, no conditionals, no dynamic evaluation. What is written is what every caller gets.

## Key Files
- `toolkit.conf` — defines all runtime defaults for the entire pipeline; every script that needs a model name, threshold, path, or concurrency limit reads from here

## Entry Points
This module has no active entry point. It is passively sourced by callers:
- `bootstrap.sh` — first sourcer; performs env validation before pipeline starts
- `master_review.sh` — sources for model names, parallelism limits, and output path conventions
- `scripts/01_generate_snapshot.sh` through `scripts/06_synthesis.sh` — each phase sources for its own relevant parameters

## External Dependencies
None. This file imports nothing and depends on no other file in the repository.

## Consumed By
- `bootstrap.sh` — sources for early validation and path setup
- `master_review.sh` — sources for orchestration-level parameters
- All six `scripts/0N_*.sh` phase scripts — each sources for phase-specific values

## Data Flow
Static file — no runtime data flow. Callers execute `source config/toolkit.conf`, which injects all keys as shell variables into the calling process's environment. No transformation, no side effects, no output artifacts.

## Review Focus Areas

### Security
- **Credential leak:** Scan for any `*_KEY`, `*_TOKEN`, `*_SECRET`, or `*_PASSWORD` assignments — none should appear; only existence checks against env vars are permissible
- **Tool binary path injection:** `SEMGREP_BIN`, `GITLEAKS_BIN`, `TRUFFLEHOG_BIN`, `OSV_SCANNER_BIN`, `LIZARD_BIN` are interpolated into shell commands by callers — if any caller expands these unquoted or inside `eval`, a path containing spaces or shell metacharacters becomes an injection vector
- **No env-var sanitization:** This file sets defaults but cannot prevent a caller's pre-existing environment from overriding them silently; verify callers do not blindly trust values that may have been externally set to malicious strings

### Performance
- `PARALLEL_LIMIT=4` caps Claude agent concurrency — verify Phase 5 (`05_ai_review.sh`) actually enforces this limit rather than spawning unbounded background jobs
- `STATIC_PARALLEL=5` controls Phase 4 tool concurrency — same enforcement question
- `MAX_SOURCE_TOKENS_PER_REVIEW=80000` is a soft budget; confirm callers truncate input and emit a warning rather than silently submitting oversized prompts and burning tokens

### Error Handling
- No validation logic lives in this file — the entire risk is that callers assume all variables are set and non-empty after sourcing; confirm `bootstrap.sh` explicitly checks each required key and exits with a clear error if any is missing or empty
- `DOCS_LIMIT_LINES=300` and `MAX_FILES_PER_MODULE=25` are warn-only thresholds — verify callers emit warnings rather than silently discarding data beyond those limits

### Business Logic
- Scoring constants (`SCORE_CRITICAL_DEDUCTION=15`, `HIGH=8`, `MEDIUM=3`, `LOW=1`) feed the synthesis phase's final score arithmetic — any change here silently alters all scores without a code change; check whether these values are cross-referenced against the spec
- `REPORT_INCLUDE_LOW_IN_MAIN=false` controls report verbosity — confirm the synthesis script reads and respects this boolean rather than hardcoding behavior

### Test Coverage
- No automated tests exist for this file; the nearest equivalent is `bootstrap.sh`'s validation block — verify it covers every required key, not just a subset
- Uncovered edge cases: key present but empty string vs. key entirely absent; `PARALLEL_LIMIT=0` or a negative integer; a float accidentally assigned to an integer constant causing `$(( ))` arithmetic errors in callers

## Known Risks / Red Flags
- **Silent env override:** Bash `source` does not protect variables that already exist in the calling environment — if `MODEL_DEFAULT` is set externally, sourcing this file will not overwrite it, causing unexpected model selection with no warning
- **Unquoted binary paths in callers:** Current values like `SEMGREP_BIN="semgrep"` are safe, but a user-supplied path containing spaces will silently break or mis-invoke the tool if callers expand the variable unquoted in command position
- **Integer-only enforcement absent:** Scoring deduction constants are semantically integers but nothing enforces this; a typo introducing a float or word would cause `$(( ))` arithmetic failures in callers at runtime with no compile-time signal

## Conventions Specific to This Module
- All keys use `UPPER_SNAKE_CASE`; callers reference variables by this convention — deviations break the implicit contract
- Comment-delimited groups must stay intact; new keys belong under their logical group, not appended to the bottom of the file
- The `# Tool paths (auto-detected if not set)` comment implies callers must implement fallback detection when a binary is absent from `PATH` — this is a caller contract, not enforced here; verify each phase script actually does so
