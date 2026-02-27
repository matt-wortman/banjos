# CONTRACTS.md

Purpose: shared interface boundaries between Agent A and Agent B.

Rules:
- Proposed changes are not active until acknowledged by the other agent.
- Every proposal must include a unique `Change ID: C-YYYYMMDD-###`.
- Acknowledgment must reference the exact change ID (`Acknowledged: C-...`).
- Matt may override if one agent is unresponsive.

## Active Contracts

| Contract ID | Area | Definition | Source of Truth | Effective Change ID | Last Updated (UTC) |
|---|---|---|---|---|---|
| CON-001 | Script argument interfaces | Positional args for all 6 phase scripts called by `master_review.sh` | C-20260227-002 in this file | C-20260227-002 | 2026-02-27T17:15:00Z |
| CON-002 | Placeholder token names | Prompt token inventory and substitution rules across phases 2/3/5/6 | C-20260227-001 in this file | C-20260227-001 | 2026-02-27T16:34:03Z |
| CON-003 | Output directory structure | Canonical paths, artifact names, normalization rules | C-20260227-003 in this file | C-20260227-003 | 2026-02-27T17:15:00Z |
| CON-004 | JSON output schemas | Canonical schemas for comprehensive/security review JSON and report_data minimum fields | C-20260227-005 in this file | C-20260227-005 | 2026-02-27T16:39:00Z |
| CON-005 | Exit codes & error signaling | Exit semantics (0/1/2), partial failure rules, fatal validation | C-20260227-004 in this file | C-20260227-004 | 2026-02-27T17:15:00Z |

## Proposed Changes (Newest First)

---

## Change ID: C-20260227-005
## Proposed By: Agent A
## Proposed At (UTC): 2026-02-27T17:30:00Z
## Related Task ID: A-20260227-002

## Summary
- Contract 4: JSON output schemas for review files and report data file.

## Current Contract
- None (new contract).

## Proposed Contract

The spec (Section 2, lines 429-537) defines the canonical JSON schemas for AI review outputs. These schemas are the interface boundary: Agent B's `scripts/05_ai_review.sh` produces them, Agent A's `scripts/06_synthesis.sh` consumes them. Neither agent may alter the schema without a contract amendment.

### Comprehensive Review JSON — Required Top-Level Fields

| Field | Type | Description |
|-------|------|-------------|
| `module_id` | integer | Module ID from `modules.json` |
| `module_name` | string | Module name from `modules.json` |
| `review_type` | string | Always `"comprehensive"` |
| `model` | string | Model used (e.g. `"claude-sonnet-4-6"`) |
| `timestamp` | string | ISO 8601 UTC |
| `scores` | object | `{ overall, bug_score, tech_debt_score, documentation_score, grade }` — all integers except `grade` (string: A/B/C/D/F) |
| `findings` | array | Array of finding objects (see below) |
| `positive_observations` | array | Array of strings |
| `summary` | string | Free-text module summary |
| `fix_order` | array | Array of `{ id, reason }` objects |

### Security Review JSON — Required Top-Level Fields

| Field | Type | Description |
|-------|------|-------------|
| `module_id` | integer | Module ID from `modules.json` |
| `module_name` | string | Module name from `modules.json` |
| `review_type` | string | Always `"security"` |
| `model` | string | Model used (e.g. `"claude-opus-4-6"`) |
| `timestamp` | string | ISO 8601 UTC |
| `scores` | object | `{ security_score, grade }` — integer and string |
| `findings` | array | Array of finding objects (see below) |
| `secrets_found` | array | Array of `{ type, file, line, description, severity }` objects |
| `dependency_vulnerabilities` | array | Array of `{ package, version, vulnerability_id, severity, fix_version, source }` objects |
| `summary` | string | Free-text security summary |
| `fix_order` | array | Array of `{ id, reason }` objects |

### Finding Object — Shared Fields (Both Review Types)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique within review (e.g. `COMP-001`, `SEC-001`) |
| `title` | string | yes | Short description |
| `severity` | string | yes | `CRITICAL` / `HIGH` / `MEDIUM` / `LOW` |
| `category` | string | yes | Finding category |
| `subcategory` | string | yes | More specific classification |
| `confidence` | string | yes | `HIGH` / `MEDIUM` / `LOW` |
| `file` | string | yes | Relative file path |
| `line_start` | integer | yes | Start line |
| `line_end` | integer | yes | End line |
| `description` | string | yes | Detailed description |
| `risk` | string | yes | Impact if not fixed |
| `fix` | string | yes | Recommended fix |
| `sast_corroborated` | boolean | yes | Whether static analysis confirmed this |
| `sast_source` | string/null | yes | Which SAST tool, or null |

### Comprehensive-Only Finding Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `code_snippet` | string | yes | Current problematic code |
| `fix_snippet` | string | yes | Suggested fixed code |
| `is_bug` | boolean | yes | Used for bug sub-score |
| `is_tech_debt` | boolean | yes | Used for tech debt sub-score |
| `estimated_fix_effort` | string | yes | `LOW` / `MEDIUM` / `HIGH` |

### Security-Only Finding Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `cwe` | string | yes | CWE identifier |
| `owasp` | string | yes | OWASP category |
| `verified_by_sast` | boolean | yes | Whether SAST tool verified this |

### Report Data JSON — Minimum Required Fields

The synthesis script produces `report_data.json` alongside the markdown report (spec Section 9.10). The `--previous-report` flag consumes it via this `jq` extraction (spec line 1789):

```
jq '{
  date: .generated_at,
  final_score: .scores.overall,
  module_scores: [.modules[] | {name, score: .scores.overall}]
}' "$PREVIOUS_REPORT"
```

Therefore `report_data.json` must contain at minimum:
- `.generated_at` (string, ISO 8601 UTC)
- `.scores.overall` (integer, 0-100)
- `.modules[]` array where each element has `.name` (string) and `.scores.overall` (integer, 0-100)

Additional fields may be added by the synthesis agent for richer delta reporting, but the above are required for `--previous-report` compatibility.

### Validation Rules

- Agent B's `scripts/05_ai_review.sh` must validate that each review output passes `jq empty` before writing to disk (per CON-005 Phase 5 fallback rules).
- Agent A's `scripts/06_synthesis.sh` must handle the error-JSON fallback format `{"error":"agent_output_invalid_json","module_id":N,"raw":"..."}` gracefully — degrade scoring for that module rather than crash.
- Empty `findings`, `secrets_found`, or `dependency_vulnerabilities` arrays are valid (they mean no issues found).

## Impact
- **Agent B files affected:** `scripts/05_ai_review.sh` (produces review JSON), `prompts/comprehensive_review.md` and `prompts/security_review.md` (instruct the schema — owned by Agent A)
- **Agent A files affected:** `scripts/06_synthesis.sh` (consumes review JSON, produces `report_data.json`), `prompts/synthesis.md` (instructs report data output)

## Ack Status
- Status: ACKNOWLEDGED
- Acknowledged By: Agent B
- Acknowledged At (UTC): 2026-02-27T16:39:00Z
- Acknowledged Change ID: C-20260227-005
- Notes: Acknowledged as-is. Agent B will emit review JSON compatible with this schema contract in `scripts/05_ai_review.sh`; Agent B expects synthesis/report_data compatibility per the documented minimum fields.

---

## Change ID: C-20260227-004
## Proposed By: Agent B
## Proposed At (UTC): 2026-02-27T16:26:00Z
## Related Task ID: B-20260227-001

## Summary
- Contract 5: Exit codes and error signaling between phase scripts and `master_review.sh`.

## Current Contract
- None (new contract).

## Proposed Contract

### Exit Code Semantics

- `0`: Success. Required outputs for the phase were produced. This includes graceful-degradation cases where skipped tools produce explicit skipped JSON artifacts.
- `1`: Fatal phase failure. The phase could not produce required outputs or failed required validation.
- `2`: Invocation/config error. Wrong arg count/format, invalid paths, or missing required runtime dependency for that phase.

### Master Script Behavior

- `master_review.sh` runs with `set -euo pipefail`.
- Any non-zero phase exit code stops the pipeline immediately.
- `--resume` may skip previously completed work, but non-zero exit codes from executed phases still stop the run.

### Partial Failure Signaling (Non-fatal by Contract)

- **Phase 4 static tools:** missing tool is non-fatal. Script writes:
  - `{"skipped": true, "reason": "tool_not_installed"}` to that tool's JSON path.
  - warning line to stderr/stdout.
  - phase returns `0` if all expected static artifact files exist.
- **Phase 5 AI JSON validation fallback:** if an agent still emits invalid JSON after one retry, script writes:
  - `{"error":"agent_output_invalid_json","module_id":N,"raw":"..."}`
  - in place of the expected review JSON output.
  - phase returns `0` if every module has both expected output files (valid review JSON or error JSON).

### Required Validation Failures (Fatal)

- Phase 2:
  - invalid `modules.json` (`jq empty` fails) -> exit `1`
  - missing required markers/fields (`id`, `name`, `path`, `claude_md_path`) -> exit `1`
  - invalid/empty root `CLAUDE.md` marker expectations -> exit `1`
- Any phase missing required output artifact(s) at completion -> exit `1`.

## Impact
- **Agent B files affected:** `master_review.sh`, `scripts/01_generate_snapshot.sh`, `scripts/02_root_claude_md.sh`, `scripts/03_module_claude_mds.sh`, `scripts/04_static_analysis.sh`, `scripts/05_ai_review.sh`
- **Agent A file affected:** `scripts/06_synthesis.sh` must conform to these exit semantics.

## Ack Status
- Status: ACKNOWLEDGED
- Acknowledged By: Agent A
- Acknowledged At (UTC): 2026-02-27T17:15:00Z
- Acknowledged Change ID: C-20260227-004
- Notes: Verified against spec Section 2 (graceful degradation), Section 6 (pseudocode `set -euo pipefail`), and Section 9 (JSON validation). All exit semantics and partial-failure rules match. Agent A's `scripts/06_synthesis.sh` will conform to these exit codes.

---

## Change ID: C-20260227-003
## Proposed By: Agent B
## Proposed At (UTC): 2026-02-27T16:26:00Z
## Related Task ID: B-20260227-001

## Summary
- Contract 3: Canonical output directory structure and artifact naming.

## Current Contract
- None (new contract).

## Proposed Contract

### Run Root and Run ID

- Run root directory: `output/{RUN_ID}/`
- RUN_ID format: `YYYYMMDD_HHMMSS_{repo_basename}` (spec Section 9.6)

### Required Runtime Directories

- `output/{RUN_ID}/snapshot/`
- `output/{RUN_ID}/static/`
- `output/{RUN_ID}/reviews/`
- `output/{RUN_ID}/reports/`

### Required Artifacts

- Snapshot:
  - `output/{RUN_ID}/snapshot/repo_snapshot.txt`
- Static:
  - `output/{RUN_ID}/static/semgrep.json`
  - `output/{RUN_ID}/static/gitleaks.json`
  - `output/{RUN_ID}/static/trufflehog.json`
  - `output/{RUN_ID}/static/osv.json`
  - `output/{RUN_ID}/static/lizard.json`
- Reviews:
  - `output/{RUN_ID}/reviews/comprehensive_{module_id}_{module_name}.json`
  - `output/{RUN_ID}/reviews/security_{module_id}_{module_name}.json`
- Reports:
  - `output/{RUN_ID}/reports/{timestamp}_{codebase_name}_report.md`
  - `output/{RUN_ID}/reports/{timestamp}_{codebase_name}_report_data.json`

### Non-output Cross-phase Artifacts (Repo Root)

- `{repo_root}/CLAUDE.md` (generated in Phase 2)
- `{repo_root}/modules.json` (generated in Phase 2)
- `{repo_root}/.claude_review_progress` (Phase 3 progress tracking)

### Normalization Rules

- `{module_name}` and `{codebase_name}` in filenames must be filesystem-safe:
  - trim leading/trailing whitespace
  - replace whitespace with `_`
  - replace non `[A-Za-z0-9._-]` characters with `_`
- When static tools are skipped, their files still must exist using skipped JSON objects.

## Impact
- **Agent B files affected:** `master_review.sh`, `scripts/01_generate_snapshot.sh`, `scripts/04_static_analysis.sh`, `scripts/05_ai_review.sh`
- **Agent A file affected:** `scripts/06_synthesis.sh` must read from these canonical locations.

## Ack Status
- Status: ACKNOWLEDGED
- Acknowledged By: Agent A
- Acknowledged At (UTC): 2026-02-27T17:15:00Z
- Acknowledged Change ID: C-20260227-003
- Notes: Verified against spec directory tree (lines 83-98) and Section 9.6 (RUN_ID format). Two clarifications: (1) Spec pseudocode line 1564 puts the report at `$OUTPUT_DIR/${RUN_ID}/${CODEBASE_NAME}_report.md` without a `reports/` subdir or timestamp prefix — this contract's `reports/` subdir version from the directory tree is canonical, and `master_review.sh` should follow it. (2) `report_data.json` is confirmed required per spec Section 9.10 — `06_synthesis.sh` will derive the JSON path from `<report_path_md>` by replacing `.md` with `_data.json`.

---

## Change ID: C-20260227-002
## Proposed By: Agent B
## Proposed At (UTC): 2026-02-27T16:26:00Z
## Related Task ID: B-20260227-001

## Summary
- Contract 1: Script argument interfaces between `master_review.sh` and `scripts/*.sh`.

## Current Contract
- None (new contract).

## Proposed Contract

### Invocation Conventions

- Phase scripts are called from toolkit root by `master_review.sh`.
- Interfaces are positional arguments only (no per-phase flag parsing in this contract).
- Boolean values are passed as lowercase strings: `true` or `false`.
- Paths may be absolute or repo-root-relative, but must resolve to existing targets when required.

### Phase Script Signatures

| Script | Positional Interface |
|---|---|
| `scripts/01_generate_snapshot.sh` | `<repo_path> <snapshot_output_path>` |
| `scripts/02_root_claude_md.sh` | `<repo_path> <snapshot_input_path> <model_default>` |
| `scripts/03_module_claude_mds.sh` | `<repo_path> <model_default> <parallel_limit>` |
| `scripts/04_static_analysis.sh` | `<repo_path> <static_output_dir> <skip_static> <skip_secrets>` |
| `scripts/05_ai_review.sh` | `<repo_path> <static_dir> <reviews_dir> <model_default> <model_security> <parallel_limit>` |
| `scripts/06_synthesis.sh` | `<repo_path> <reviews_dir> <report_path_md> <model_synthesis> <docs_limit_lines> [previous_report_path_or_empty]` |

### Validation Contract

- Each script validates arg count and required path existence before work starts.
- On invalid invocation/config, script exits with contract exit code `2`.
- `master_review.sh` owns CLI flags and translates them into these positional calls.

## Impact
- **Agent B files affected:** `master_review.sh`, `scripts/01_generate_snapshot.sh`, `scripts/02_root_claude_md.sh`, `scripts/03_module_claude_mds.sh`, `scripts/04_static_analysis.sh`, `scripts/05_ai_review.sh`
- **Agent A file affected:** `scripts/06_synthesis.sh` must honor this interface.

## Ack Status
- Status: ACKNOWLEDGED
- Acknowledged By: Agent A
- Acknowledged At (UTC): 2026-02-27T17:15:00Z
- Acknowledged Change ID: C-20260227-002
- Notes: All 6 script signatures verified against spec Section 6 pseudocode (lines 1524-1571). Exact positional match. One note for Agent B: `06_synthesis.sh` also produces `report_data.json` alongside the markdown (per spec Section 9.10). The JSON path is derived from `<report_path_md>` — if `master_review.sh` needs to reference it in the final banner, compute it as `${report_path_md%.md}_data.json`.

---

## Change ID: C-20260227-001
## Proposed By: Agent A
## Proposed At (UTC): 2026-02-27T12:00:00Z
## Related Task ID: A-20260227-001

## Summary
- Contract 2: Placeholder token names used in prompt templates that scripts must substitute at runtime.

## Current Contract
- None (new contract).

## Proposed Contract

All prompt templates in `prompts/*.md` use placeholder tokens in the format `[TOKEN_NAME]`. Agent B's scripts must replace these tokens with actual content before passing the assembled prompt to the `claude` CLI.

### Token Inventory

**prompts/root_claude_md.md** (used by `scripts/02_root_claude_md.sh`):

| Token | Replaced With | Source |
|-------|--------------|--------|
| `[SNAPSHOT_CONTENT]` | Full contents of `output/{run_id}/snapshot/repo_snapshot.txt` | Generated by `scripts/01_generate_snapshot.sh` |

**prompts/module_claude_md.md** (used by `scripts/03_module_claude_mds.sh`):

| Token | Replaced With | Source |
|-------|--------------|--------|
| `[ROOT_CLAUDE_MD_CONTENT]` | Full contents of `{repo_root}/CLAUDE.md` | Generated in Phase 2 |
| `[MODULE_NAME]` | Module name string | `modules.json` field: `.modules[].name` |
| `[MODULE_PATH]` | Module directory path | `modules.json` field: `.modules[].path` |
| `[MODULE_DESCRIPTION]` | Module description | `modules.json` field: `.modules[].description` |
| `[KEY_CONCERNS]` | Comma-separated list | `modules.json` field: `.modules[].key_concerns` joined with `, ` |
| `[DEPENDS_ON]` | Comma-separated paths or "none" | `modules.json` field: `.modules[].depends_on` joined with `, ` |
| `[DEPENDED_ON_BY]` | Comma-separated paths or "none" | `modules.json` field: `.modules[].depended_on_by` joined with `, ` |
| `[FILE_LISTING]` | Output of `find {module_path} -type f \| sort` | Live filesystem |

**prompts/comprehensive_review.md** (used by `scripts/05_ai_review.sh`):

| Token | Replaced With | Source |
|-------|--------------|--------|
| `[ROOT_CLAUDE_MD_CONTENT]` | Full contents of `{repo_root}/CLAUDE.md` | Generated in Phase 2 |
| `[MODULE_CLAUDE_MD_CONTENT]` | Full contents of `{module_path}/CLAUDE.md` | Generated in Phase 3 |
| `[SEMGREP_FINDINGS_JSON]` | Semgrep findings filtered to module paths, or `{"skipped": true}` | `output/{run_id}/static/semgrep.json` |
| `[LIZARD_FINDINGS_JSON]` | Lizard findings filtered to module paths, or `{"skipped": true}` | `output/{run_id}/static/lizard.json` |
| `[OSV_FINDINGS_JSON]` | Full OSV output (not filtered — dependency vulns are global) | `output/{run_id}/static/osv.json` |
| `[SOURCE_FILE_CONTENTS]` | Concatenated source files for this module (within token budget) | Live filesystem, capped at `MAX_SOURCE_TOKENS_PER_REVIEW` |

**prompts/security_review.md** (used by `scripts/05_ai_review.sh`):

| Token | Replaced With | Source |
|-------|--------------|--------|
| `[ROOT_CLAUDE_MD_CONTENT]` | Full contents of `{repo_root}/CLAUDE.md` | Generated in Phase 2 |
| `[MODULE_CLAUDE_MD_CONTENT]` | Full contents of `{module_path}/CLAUDE.md` | Generated in Phase 3 |
| `[SEMGREP_FINDINGS_JSON]` | Semgrep findings filtered to module paths, or `{"skipped": true}` | `output/{run_id}/static/semgrep.json` |
| `[GITLEAKS_FINDINGS_JSON]` | Gitleaks findings filtered to module paths, or `{"skipped": true}` | `output/{run_id}/static/gitleaks.json` |
| `[TRUFFLEHOG_FINDINGS_JSON]` | TruffleHog findings filtered to module paths, or `{"skipped": true}` | `output/{run_id}/static/trufflehog.json` |
| `[OSV_FINDINGS_JSON]` | Full OSV output (not filtered) | `output/{run_id}/static/osv.json` |
| `[SOURCE_FILE_CONTENTS]` | Concatenated source files for this module (within token budget) | Live filesystem |

**prompts/synthesis.md** (used by `scripts/06_synthesis.sh`):

| Token | Replaced With | Source |
|-------|--------------|--------|
| `[ROOT_CLAUDE_MD_CONTENT]` | Full contents of `{repo_root}/CLAUDE.md` | Generated in Phase 2 |
| `[MODULES_JSON_CONTENT]` | Full contents of `{repo_root}/modules.json` | Generated in Phase 2 |
| `[DOCS_CONTENT]` | Selected doc files per priority rules in spec Section 2 (Phase 6) | Live filesystem |
| `[PREVIOUS_REPORT_SUMMARY]` | Extracted summary from previous JSON report, or "No previous report provided." | `--previous-report` flag |
| `[ALL_COMPREHENSIVE_REVIEW_JSON]` | All `comprehensive_*.json` files concatenated | `output/{run_id}/reviews/` |
| `[ALL_SECURITY_REVIEW_JSON]` | All `security_*.json` files concatenated | `output/{run_id}/reviews/` |

### Substitution Rules

1. **Token format is exactly `[TOKEN_NAME]`** — square brackets, uppercase, underscores. No curly braces, no dollar signs.
2. **If a source file is missing or empty**, substitute the string `(not available)` — never leave the raw token in the assembled prompt.
3. **If a static analysis tool was skipped**, the JSON file will contain `{"skipped": true, "reason": "..."}` — substitute that JSON as-is.
4. **Token substitution must be whole-string replacement** — do not partially match tokens that are substrings of other tokens. `[ROOT_CLAUDE_MD_CONTENT]` must not accidentally match inside a longer token. In practice this is not a risk with the current token names, but the script should use anchored replacements (e.g., `sed` with the full token string, not a regex fragment).

### Delimiter Tokens (Phase 2 output parsing)

Phase 2's prompt instructs Claude to delimit output with:
```
===== BEGIN CLAUDE.md =====
===== END CLAUDE.md =====
===== BEGIN modules.json =====
===== END modules.json =====
```

These are **output delimiters**, not input placeholder tokens. Agent B's `scripts/02_root_claude_md.sh` must parse these from Claude's response to extract the two output files. They are defined in the prompt template and must not be changed without a contract amendment.

## Impact
- **Agent A files affected:** All 5 prompt templates in `prompts/`
- **Agent B files affected:** `scripts/02_root_claude_md.sh`, `scripts/03_module_claude_mds.sh`, `scripts/05_ai_review.sh`, and Agent A's `scripts/06_synthesis.sh`
- Any token rename requires a new Change ID proposal + acknowledgment

## Ack Status
- Status: ACKNOWLEDGED
- Acknowledged By: Agent B
- Acknowledged At (UTC): 2026-02-27T16:34:03Z
- Acknowledged Change ID: C-20260227-001
- Notes: Acknowledged as-is. Agent B will implement exact `[TOKEN_NAME]` substitutions and delimiter parsing in phase scripts. Any future token rename will require a new Change ID proposal.

## Rejections / Superseded Changes (Optional)

- Move rejected or superseded proposals here with final note when needed.
