# CLAUDE.md — Bootstrap & Orchestration

## Module Purpose
This module is the sole external interface to the toolkit. `bootstrap.sh` is a one-time setup validator — it checks for required tools and optionally installs Python-based extras. `master_review.sh` is the runtime entry point: it validates arguments, loads config, generates the run ID and all output directory paths, then sequences the six phase scripts in strict order. No business logic lives here — this module owns environment safety, argument parsing, and pipeline coordination.

## Internal Structure
`bootstrap.sh` is standalone — it has no callers and delegates to nothing. It exits 1 if required tools are missing.

`master_review.sh` owns the full execution flow:
1. Validates `$REPO_PATH` argument before touching anything else
2. Sources `config/toolkit.conf` (soft — skipped if absent)
3. Parses all `--flag VALUE` options with manual shift-based loop
4. Validates numeric options (`--parallel-limit`, `--docs-limit`, `--only-phase`)
5. Generates or resolves the `RUN_ID` (new vs `--resume`)
6. Creates all four output subdirectories upfront
7. Calls `should_run_phase` + `phaseN_done` guards around each `run_cmd` invocation

## Key Files
- `bootstrap.sh` — Pre-flight tool checker; run once before first use or in CI to validate environment
- `master_review.sh` — Pipeline orchestrator; the only file that calls phase scripts; owns `RUN_ID` lifecycle, all path construction, and `--resume` idempotency logic

## Entry Points
- `./bootstrap.sh [--install-python-tools]` — Direct user/CI invocation; no arguments required
- `./master_review.sh <repo_path> [OPTIONS]` — Requires a valid directory as $1; all other options are optional with defaults from `toolkit.conf`

## External Dependencies
- `config/toolkit.conf` — Sourced by `master_review.sh` to override defaults; absence is tolerated silently
- `scripts/01_generate_snapshot.sh` through `scripts/06_synthesis.sh` — Invoked positionally via `run_cmd`; paths resolved relative to `SCRIPT_DIR`
- `jq` — Required at runtime in `master_review.sh` for `phase3_done` and `phase5_done` completion checks
- `claude`, `jq`, `python3` — Required tools checked by `bootstrap.sh`

## Consumed By
Nothing — this is the top of the call graph. Users and CI systems invoke these scripts directly.

## Data Flow
```
User invokes master_review.sh <repo_path> [--flags]
  → Load config/toolkit.conf (soft)
  → Parse CLI flags (override config defaults)
  → Validate REPO_PATH, PARALLEL_LIMIT, DOCS_LIMIT_LINES, ONLY_PHASE, PREVIOUS_REPORT
  → Resolve or generate RUN_ID (new timestamp or --resume lookup)
  → Construct all paths (RUN_ROOT, SNAPSHOT_DIR, STATIC_DIR, REVIEWS_DIR, REPORTS_DIR)
  → mkdir -p all four output subdirs
  → For each phase 1–6:
      should_run_phase? → phase_done() idempotency check → run_cmd → phase script
  → Print final report path + overall score from report_data.json
```

## Review Focus Areas

### Security
- `bootstrap.sh` invokes `pip3 install "$package"` with an unvalidated user-supplied string — the `--install-python-tools` flag installs fixed package names (`semgrep`, `lizard`, `pip-audit`) so injection risk is low, but verify no path through which `$package` receives external input
- `master_review.sh` passes `$REPO_PATH` directly as a positional argument to phase scripts — if a phase script interpolates this into a shell command without quoting, path injection is possible; verify all phase scripts quote `"$1"` consistently
- `sanitize_name()` strips spaces and non-alphanumeric chars — review whether the regex is tight enough to prevent directory traversal in the constructed output paths
- `SAFE_CODEBASE_NAME` is used in report filenames — verify `sanitize_name` output cannot contain `../` sequences after substitution

### Performance
- `phase3_done` and `phase5_done` both invoke `jq` in a loop via process substitution — for repos with many modules this could be slow, but is only called once per resume check, so not a hot path
- `find` in the `--resume` RUN_ID lookup (`-printf '%f\n' | sort | tail -n 1`) could be slow on large output directories with thousands of runs

### Error Handling
- `master_review.sh` uses `set -euo pipefail` — any phase script exit non-zero will abort the entire pipeline without cleanup; there is no trap handler to print which phase failed or clean up partial artifacts
- The `run_cmd` wrapper swallows the description of what failed — on error the user sees the phase script's stderr but not a banner identifying which phase number failed
- `phase4_done` checks for all five static artifact files; if any single tool was skipped via `--skip-static` or `--skip-secrets`, `phase4_done` will return false even after a valid partial run, causing `--resume` to always re-run Phase 4
- `bootstrap.sh` uses `|| true` on `install_python_tool` calls — installation failures are silently swallowed; the script exits 0 even when optional tools failed to install

### Business Logic
- Config sourcing happens before CLI flag parsing — this is the correct precedence (CLI overrides config), but if `toolkit.conf` sets a value and no CLI flag is passed, the config value is used without any visibility to the user at runtime
- `ONLY_PHASE` combined with `--resume` has subtle behavior: `should_run_phase` returns false for all phases except the targeted one, but `phase_done` guards still apply and may skip the targeted phase anyway if its artifacts already exist
- `REPORT_PATH_MD` embeds a second `date` call (`REPORT_TIMESTAMP`) separate from `RUN_ID` — these two timestamps will differ if the clock ticks between lines 202 and 213; for `--resume` runs the report path will always be a new timestamped file, never resuming an existing report

### Test Coverage
- No tests exist for the argument parser — especially the `--only-phase` + `--resume` combination and the `--parallel-limit` / `--docs-limit` integer validation
- `sanitize_name()` has no tests; edge cases with leading dots, slashes, or all-whitespace input are unverified
- `phase_done()` functions have no tests — the idempotency logic for `--resume` is entirely untested

## Known Risks / Red Flags
- **No trap handler** — a failed phase leaves the pipeline in a partially-written state with no indication of where it stopped; `--resume` may then skip the failed phase because `phase_done` checks artifact existence, not integrity
- **Silent config override** — `source "$CONFIG_PATH"` with `# shellcheck disable=SC1090` means any variable in `toolkit.conf` silently overrides the hardcoded defaults, including model names and output paths; a malformed config can redirect output or change model behavior with no error message
- **`$REPO_PATH` is caller-controlled** — it is passed verbatim to six different phase scripts; a path containing spaces that a phase script fails to quote would cause subtle splitting bugs

## Conventions Specific to This Module
- `run_cmd` is the sole execution wrapper — in `--dry-run` mode it prints the command without running it; all phase invocations must go through `run_cmd` to honor this flag
- Phase completion guards follow the pattern `phaseN_done()` returning 0/1 based on artifact file existence — these are purely filesystem checks, not semantic validation
- `SCRIPT_DIR` is resolved via `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` — the canonical pattern for self-relative paths; any future scripts added to this module should replicate this exactly
- CLI flag parsing uses manual `shift`-based `while/case` rather than `getopts` — this is intentional to support long `--flags`; maintain this pattern if adding new options
