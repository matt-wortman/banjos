# CODE REVIEW TOOLKIT — COMPLETE IMPLEMENTATION SPECIFICATION
# ============================================================
# VERSION: 1.0
# PURPOSE: Complete specification for building the code-review-toolkit
#          package from scratch. Written for multiple parallel agents
#          whose outputs will be merged into a single package.
#
# This document is self-contained. No prior context is required.
# ============================================================

---

# SECTION 0: OVERVIEW AND PHILOSOPHY

## What This Toolkit Does

The code-review-toolkit is a fully automated, multi-phase codebase
quality scanner that produces a single, comprehensive Markdown report
broken down by module. It combines:

1. Free open-source static analysis tools (deterministic, fast, low context)
2. Claude AI agents (contextual, semantic, reasoning-based)

The two approaches are intentionally layered: static tools run FIRST and
their JSON output is fed INTO Claude agents as grounding data. Research
has demonstrated this hybrid approach achieves ~91% reduction in false
positives versus either tool used alone.

## Output: The Final Report

One Markdown file. Module-first structure. Contains:
- Codebase name + final weighted quality score
- Codebase purpose and inferred context
- Top recommendations (critical/high findings sorted by fix priority,
  accounting for cross-module dependencies)
- Per-module deep dives, each containing:
  - Module quality score (0-100, grade A-F)
  - Bug score (0-100)
  - Tech debt score (0-100)
  - Documentation quality score (0-100)
  - Security findings
  - Performance findings
  - Code quality findings
  - Test coverage assessment
  - Fix-order recommendations for this module

## Repository Structure (Final)

```
code-review-toolkit/
│
├── master_review.sh                 ← SINGLE ENTRY POINT
│
├── bootstrap.sh                     ← one-time setup (installs deps)
│
├── README.md                        ← how to use this tool
│
├── scripts/
│   ├── 01_generate_snapshot.sh      ← Phase 1: structural snapshot
│   ├── 02_root_claude_md.sh         ← Phase 2: root CLAUDE.md + modules.json
│   ├── 03_module_claude_mds.sh      ← Phase 3: per-module CLAUDE.md (parallel)
│   ├── 04_static_analysis.sh        ← Phase 4: run all static tools (parallel)
│   ├── 05_ai_review.sh              ← Phase 5: run Claude agents (parallel)
│   └── 06_synthesis.sh             ← Phase 6: synthesis agent → final report
│
├── .claude/
│   └── agents/
│       ├── architect.md             ← generates CLAUDE.md files
│       ├── comprehensive-reviewer.md ← broad module review agent
│       ├── security-reviewer.md     ← deep security agent (Opus)
│       └── synthesis.md             ← report assembly agent (Opus)
│
├── prompts/
│   ├── root_claude_md.md            ← Prompt 1 template
│   ├── module_claude_md.md          ← Prompt 2 template
│   ├── comprehensive_review.md      ← Prompt 3a template
│   ├── security_review.md           ← Prompt 3b template
│   └── synthesis.md                 ← Prompt 4 template
│
├── config/
│   └── toolkit.conf                 ← default configuration values
│
└── output/                          ← created at runtime, gitignored
    ├── {run_id}/
    │   ├── snapshot/
    │   │   └── repo_snapshot.txt
    │   ├── static/
    │   │   ├── semgrep.json
    │   │   ├── gitleaks.json
    │   │   ├── trufflehog.json
    │   │   ├── osv.json
    │   │   └── lizard.json
    │   ├── reviews/
    │   │   ├── comprehensive_{module}.json
    │   │   └── security_{module}.json
    │   └── reports/
    │       ├── {timestamp}_{codebase_name}_report.md
    │       └── {timestamp}_{codebase_name}_report_data.json
```

---

# SECTION 1: INVOCATION

## Primary Command

```bash
./master_review.sh /path/to/repo [OPTIONS]
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--name NAME` | dirname of repo | Human-readable codebase name for report |
| `--output DIR` | ./output | Where to write all output |
| `--model-default MODEL` | claude-sonnet-4-6 | Model for non-security agents |
| `--model-security MODEL` | claude-opus-4-6 | Model for security agent |
| `--model-synthesis MODEL` | claude-opus-4-6 | Model for synthesis agent |
| `--skip-static` | false | Skip static analysis tools (faster, lower quality) |
| `--skip-secrets` | false | Skip secret scanning (use if repo has no .git) |
| `--resume` | false | Skip phases that already completed for this repo |
| `--previous-report PATH` | none | Path to a previous JSON report for delta scoring |
| `--docs-limit LINES` | 300 | Max lines to read from any single doc file |
| `--parallel-limit N` | 4 | Max concurrent Claude agents at once |
| `--only-phase N` | all | Run only a specific phase (1-6) |
| `--dry-run` | false | Print what would run without executing |

## Example Invocations

```bash
# Basic run
./master_review.sh /path/to/my-backend

# Full run with custom name and Opus for everything
./master_review.sh /path/to/my-backend \
  --name "WealthLens Backend" \
  --model-default claude-opus-4-6

# Resume after failure
./master_review.sh /path/to/my-backend --resume

# Skip static tools (use Claude only — faster but lower quality)
./master_review.sh /path/to/my-backend --skip-static

# Compare against previous report for delta scores
./master_review.sh /path/to/my-backend \
  --previous-report ./output/2026-01-15_WealthLens_report_data.json
```

---

# SECTION 2: PHASE DESCRIPTIONS

## Phase 1 — Structural Snapshot (scripts/01_generate_snapshot.sh)

Generates a lightweight text file capturing the skeleton of the
repository without reading implementation code.

### What it captures:
- Directory tree (depth 4, excludes node_modules/.git/dist/build/etc)
- Contents of package.json / requirements.txt / go.mod / Cargo.toml /
  pyproject.toml / Gemfile / pom.xml / composer.json (lock files truncated)
- Config file PATHS only (never contents — security risk)
- Files matching: route/controller/handler/resolver patterns
- Files matching: model/schema/entity/migration/repository patterns
- Files matching: middleware/interceptor/guard patterns
- Files matching: auth/security/token/jwt/oauth patterns
- Files matching: service/usecase/worker/job/queue/event patterns
- Test files (*.test.*, *.spec.*, test_*, *_test.*)
- File extension summary (count per extension)
- Total file count

### Output:
- output/{run_id}/snapshot/repo_snapshot.txt

### Key implementation details:
- Uses `tree` command if available, falls back to `find` simulation
- Excludes these dirs from ALL find operations:
  .git, node_modules, dist, build, out, .next, .nuxt, coverage,
  __pycache__, .pytest_cache, .mypy_cache, .tox, venv, .venv, env,
  vendor, target, .cargo, .gradle, .idea, .vscode
- Config file paths captured but NEVER their contents

---

## Phase 2 — Root CLAUDE.md + modules.json (scripts/02_root_claude_md.sh)

Spawns a single Claude agent (Sonnet) that reads the snapshot and
produces two files: the root CLAUDE.md and a machine-readable
modules.json manifest.

### Claude agent invocation:
```bash
claude \
  --model "$MODEL_DEFAULT" \
  --dangerously-skip-permissions \
  -p "$ASSEMBLED_PROMPT" \
  > output/{run_id}/phase2_raw.txt
```

### The assembled prompt combines:
1. prompts/root_claude_md.md (the template — see Section 3)
2. Contents of output/{run_id}/snapshot/repo_snapshot.txt

### Parsing the output:
The prompt instructs Claude to use delimiter markers:
```
===== BEGIN CLAUDE.md =====
[content]
===== END CLAUDE.md =====

===== BEGIN modules.json =====
[content]
===== END modules.json =====
```

The script parses these delimiters using awk/sed and writes:
- CLAUDE.md to the REPO ROOT (not the output dir)
- modules.json to the REPO ROOT (not the output dir)

### Validation:
- modules.json must parse as valid JSON (`jq empty`)
- CLAUDE.md must contain "# CLAUDE.md"
- modules.json must have at minimum: id, name, path, claude_md_path per module
- If validation fails: print error, exit with code 1

### Output:
- {repo_root}/CLAUDE.md
- {repo_root}/modules.json

---

## Phase 3 — Per-Module CLAUDE.md Files (scripts/03_module_claude_mds.sh)

Reads modules.json. Spawns one Claude agent per module IN PARALLEL
(up to --parallel-limit at once). Each agent generates a CLAUDE.md
file for its assigned module directory.

### Parallelism implementation:
```bash
# Spawn agents in background, track PIDs
for module_id in $(jq -r '.review_order[]' modules.json); do
  run_module_agent "$module_id" &
  PIDS+=($!)
  
  # Throttle to parallel-limit
  while [ $(jobs -r | wc -l) -ge "$PARALLEL_LIMIT" ]; do
    sleep 1
  done
done

# Wait for all to finish before proceeding to Phase 4
wait
```

### Per-module agent input:
- prompts/module_claude_md.md template
- Root CLAUDE.md contents
- Module metadata from modules.json (name, path, description,
  key_concerns, depends_on, depended_on_by)
- File listing: `find {module_path} -type f | sort` (paths only — no contents)

### Validation per module:
- Output file must contain "# CLAUDE.md —"
- Must be at least 30 lines
- Written to {repo_root}/{module.path}/CLAUDE.md

### Progress tracking:
- .claude_review_progress file in repo root
- Format: module_{id}=DONE|FAILED|SKIPPED

### Output:
- {repo_root}/{module.path}/CLAUDE.md for every module

---

## Phase 4 — Static Analysis (scripts/04_static_analysis.sh)

Runs ALL available static analysis tools against the repo.
Each tool runs independently. Missing tools are skipped gracefully
with a warning (never a hard failure).

### Tools and what they scan:

#### 4a. Semgrep CE (SAST — security vulnerabilities)
```bash
semgrep scan \
  --config "p/default" \
  --config "p/owasp-top-ten" \
  --config "p/secrets" \
  --json \
  --output output/{run_id}/static/semgrep.json \
  {repo_path}
```
- Detects: injection, XSS, SSRF, IDOR, broken auth, insecure deserialization, etc.
- Languages: auto-detected (supports 40+)
- Output: JSON with findings array including rule_id, path, line, severity, message
- Install: `pip install semgrep` or `brew install semgrep`

#### 4b. Gitleaks (Secret detection — fast)
```bash
gitleaks detect \
  --source {repo_path} \
  --report-format json \
  --report-path output/{run_id}/static/gitleaks.json \
  --no-git  # use if not a git repo, remove for git repos
```
- Detects: API keys, passwords, tokens, private keys
- Output: JSON with findings array including RuleID, File, Line, Secret (redacted)
- Install: `brew install gitleaks` or download binary from GitHub releases
- NOTE: For git repos (default): remove --no-git to also scan git history

#### 4c. TruffleHog (Secret detection — thorough with verification)
```bash
trufflehog filesystem \
  --directory {repo_path} \
  --json \
  --no-verification \  # Remove this to verify secrets against live APIs
  2>/dev/null \
  | jq -s '.' > output/{run_id}/static/trufflehog.json
```
- Detects: 800+ credential types with entropy analysis
- Output: NDJSON (newline-delimited JSON) — pipe through `jq -s '.'` to array
- Install: `brew install trufflehog` or download binary from GitHub releases
- NOTE: Remove --no-verification for live secret verification (slower, more network)

#### 4d. OSV-Scanner (Dependency vulnerabilities)
```bash
osv-scanner \
  --format json \
  --output output/{run_id}/static/osv.json \
  {repo_path}
```
- Detects: Known CVEs in npm/pip/go/cargo/composer/gem/nuget/etc. dependencies
- Supports: package.json, requirements.txt, go.sum, Cargo.lock, composer.lock, etc.
- Output: JSON with results array including packages and vulnerabilities
- Install: `brew install osv-scanner` or download binary from GitHub
- Fallback if osv-scanner not present: run `npm audit --json` and/or `pip-audit --format json`

#### 4e. Lizard (Cyclomatic & cognitive complexity)
```bash
lizard {repo_path} \
  --language python,javascript,typescript,java,go,ruby,swift,kotlin,rust,cpp \
  --CCN 10 \
  --length 100 \
  --arguments 6 \
  --output_file output/{run_id}/static/lizard.json \
  --json
```
- Detects: Functions exceeding complexity thresholds
- Metrics: Cyclomatic complexity, cognitive complexity, function length, parameter count
- Thresholds (warnings generated when exceeded):
  - CCN (cyclomatic complexity): > 10 = warning, > 20 = high complexity
  - Function length: > 100 lines = warning
  - Parameters: > 6 = warning
- Output: JSON with function-level metrics
- Install: `pip install lizard`

### Graceful degradation:
Each tool check pattern:
```bash
if command -v semgrep &>/dev/null; then
  run_semgrep
  echo "✅ Semgrep complete"
else
  echo "⚠️  Semgrep not installed — skipping (run bootstrap.sh to install)"
  echo '{"skipped": true, "reason": "tool_not_installed"}' \
    > output/{run_id}/static/semgrep.json
fi
```

### Parallel execution:
All 5 static tools run IN PARALLEL:
```bash
run_semgrep &
run_gitleaks &
run_trufflehog &
run_osv &
run_lizard &
wait
```

### Output:
- output/{run_id}/static/semgrep.json
- output/{run_id}/static/gitleaks.json
- output/{run_id}/static/trufflehog.json
- output/{run_id}/static/osv.json
- output/{run_id}/static/lizard.json

---

## Phase 5 — AI Review (scripts/05_ai_review.sh)

For each module, spawns TWO Claude agents IN PARALLEL:
1. Comprehensive reviewer (Sonnet) — broad coverage across all dimensions
2. Security reviewer (Opus) — deep security focus

For N modules: 2N agents total, with parallel-limit throttling.

### Per-module comprehensive review input:
- prompts/comprehensive_review.md template
- Root CLAUDE.md
- Module CLAUDE.md
- Actual source file contents for this module
  (files listed in modules.json for this module, read from disk)
- Static analysis findings FILTERED to this module's file paths:
  - Relevant semgrep findings
  - Relevant lizard findings
  - OSV findings (included in all modules, not filtered by path)
- NOTE: gitleaks + trufflehog findings go to security reviewer only

### Per-module security review input:
- prompts/security_review.md template
- Root CLAUDE.md
- Module CLAUDE.md
- Actual source file contents for this module
- ALL static security findings for this module:
  - semgrep findings (filtered to module paths)
  - gitleaks findings (filtered to module paths)
  - trufflehog findings (filtered to module paths)
  - osv findings (all — dependency vulns are global)

### Output format (both agents):
Both agents must output VALID JSON (not markdown).
The prompt explicitly instructs: "Respond with ONLY valid JSON.
No preamble, no explanation, no markdown code fences."

### Comprehensive review JSON schema:
```json
{
  "module_id": 1,
  "module_name": "Authentication",
  "review_type": "comprehensive",
  "model": "claude-sonnet-4-6",
  "timestamp": "2026-02-27T10:30:00Z",
  "scores": {
    "overall": 72,
    "bug_score": 68,
    "tech_debt_score": 71,
    "documentation_score": 80,
    "grade": "C"
  },
  "findings": [
    {
      "id": "COMP-001",
      "title": "Missing pagination on /users list endpoint",
      "severity": "HIGH",
      "category": "PERFORMANCE",
      "subcategory": "unbounded_query",
      "confidence": "HIGH",
      "file": "src/api/users.controller.ts",
      "line_start": 45,
      "line_end": 52,
      "description": "The findAll() method queries all users with no LIMIT clause...",
      "risk": "With 100k+ users this will cause timeout and OOM errors",
      "fix": "Add pagination params: skip/take or cursor-based pagination",
      "code_snippet": "const users = await this.userRepo.findAll();",
      "fix_snippet": "const users = await this.userRepo.findAll({ skip, take: limit });",
      "is_bug": true,
      "is_tech_debt": false,
      "estimated_fix_effort": "LOW",
      "sast_corroborated": false,
      "sast_source": null
    }
  ],
  "positive_observations": [
    "Consistent use of TypeScript strict mode throughout",
    "All async functions properly await promises"
  ],
  "summary": "The auth module handles core flows well but has several...",
  "fix_order": [
    {"id": "COMP-003", "reason": "Critical — auth bypass"},
    {"id": "COMP-001", "reason": "High — affects all users"},
    {"id": "COMP-007", "reason": "Medium — tech debt accumulating"}
  ]
}
```

### Security review JSON schema:
```json
{
  "module_id": 1,
  "module_name": "Authentication",
  "review_type": "security",
  "model": "claude-opus-4-6",
  "timestamp": "2026-02-27T10:31:00Z",
  "scores": {
    "security_score": 55,
    "grade": "D"
  },
  "findings": [
    {
      "id": "SEC-001",
      "title": "JWT secret read from environment without fallback guard",
      "severity": "CRITICAL",
      "category": "SECURITY",
      "subcategory": "broken_authentication",
      "cwe": "CWE-798",
      "owasp": "A07:2021",
      "confidence": "HIGH",
      "file": "src/auth/jwt.service.ts",
      "line_start": 12,
      "line_end": 14,
      "description": "process.env.JWT_SECRET is used directly with no null check...",
      "risk": "If JWT_SECRET is undefined, the app signs tokens with 'undefined'...",
      "fix": "Throw at startup if JWT_SECRET is not set. Never use a default.",
      "sast_corroborated": true,
      "sast_source": "semgrep:rule_id_here",
      "verified_by_sast": true
    }
  ],
  "secrets_found": [
    {
      "type": "Detected by gitleaks",
      "file": "src/config/db.ts",
      "line": 8,
      "description": "Hardcoded connection string — REDACTED",
      "severity": "CRITICAL"
    }
  ],
  "dependency_vulnerabilities": [
    {
      "package": "jsonwebtoken",
      "version": "8.5.1",
      "vulnerability_id": "GHSA-27h2-hvpr-p74q",
      "severity": "HIGH",
      "fix_version": "9.0.0",
      "source": "osv-scanner"
    }
  ],
  "summary": "The auth module has critical security issues...",
  "fix_order": [
    {"id": "SEC-001", "reason": "Immediate — can be exploited now"},
    {"id": "DEP-001", "reason": "Update jsonwebtoken before next deploy"}
  ]
}
```

### Output:
- output/{run_id}/reviews/comprehensive_{module_id}_{module_name}.json
- output/{run_id}/reviews/security_{module_id}_{module_name}.json

---

## Phase 6 — Synthesis (scripts/06_synthesis.sh)

Single agent (Opus). Reads ALL review JSON files plus selective docs.
Produces the final Markdown report.

### Docs selection logic:
```bash
# Priority 1: Always read in full (capped at 500 lines each)
PRIORITY_1=(README.md README.rst ARCHITECTURE.md DESIGN.md SECURITY.md)

# Priority 2: Read first --docs-limit lines only
PRIORITY_2=(
  docs/architecture.md
  docs/api.md
  docs/overview.md
  openapi.yaml
  swagger.yaml
  swagger.json
  .env.example  # env var names only — never .env itself
)

# Never read:
# - CHANGELOG.md, CHANGELOG.rst, release-notes.md
# - Any file matching .env (not .env.example)
# - Any file in node_modules/, vendor/, dist/
```

### Synthesis agent input:
- prompts/synthesis.md template
- Root CLAUDE.md
- modules.json (for module order and metadata)
- All comprehensive review JSON files (all modules)
- All security review JSON files (all modules)
- Selected doc file contents (with token budget)
- Optional: previous report JSON (if --previous-report flag used)

### Scoring model (synthesis agent must apply this):

#### Per-module scores (computed from finding counts):

```
Base score = 100

Deductions:
  CRITICAL finding: -15 per finding
  HIGH finding:     -8 per finding
  MEDIUM finding:   -3 per finding
  LOW finding:      -1 per finding

Floor: 0 (cannot go negative)

Grade:
  90-100: A — Production ready
  75-89:  B — Minor issues, ship with awareness
  60-74:  C — Needs attention before major releases
  40-59:  D — Significant work required
  0-39:   F — Do not ship

Three sub-scores apply the same formula but filtered:
  Bug score:         count only is_bug=true findings
  Tech debt score:   count only is_tech_debt=true findings
  Documentation score: use documentation_score from comprehensive review directly
```

#### Codebase-wide score:
```
Weighted average of module overall scores
Weight = estimated_file_count for that module (larger modules count more)

Final score = sum(module_score × module_file_count) / sum(module_file_counts)
```

#### Delta score (only if --previous-report provided):
```
Show: current_score - previous_score with ▲/▼ indicator
Show: which modules improved, which regressed
Show: findings resolved since last scan
```

### Fix-order algorithm (synthesis must execute this):

The synthesis agent must compute a cross-module fix priority list:

1. Start with all CRITICAL and HIGH findings across all modules
2. Sort by: (a) severity DESC, (b) number of other modules that depend
   on this module DESC, (c) estimated_fix_effort ASC
3. For each finding, note which modules are "unlocked" by fixing it
   (i.e., if auth module has a critical, fixing it removes risk from
   all modules that depend_on auth)
4. Output as ordered numbered list with rationale for each position

### Output: Final Report Structure

The synthesis agent must produce a Markdown report with EXACTLY this
structure, in this order:

```markdown
# {Codebase Name} — Quality Report

> Generated: {date} | Scanner: code-review-toolkit v1.0

---

## Final Score: {score}/100 — Grade {letter}

| Dimension | Score | Grade |
|-----------|-------|-------|
| Overall Quality | {n}/100 | {letter} |
| Security | {n}/100 | {letter} |
| Bug Density | {n}/100 | {letter} |
| Technical Debt | {n}/100 | {letter} |
| Documentation | {n}/100 | {letter} |

{If previous report: show delta table with ▲▼ per score}

---

## Codebase Overview

{2-4 paragraphs covering:
- Inferred purpose and what the application does
- Tech stack summary
- Architecture pattern
- Scale indicators (file count, module count, language spread)
- Overall impression going into the detailed findings}

---

## Top Recommendations

> These are the highest-priority fixes across the entire codebase,
> ordered by impact × urgency × fix-order dependency.

### 🚨 Fix Immediately (Critical)

**1. {Title}** — {Module}
- **File**: {path}, line {n}
- **Issue**: {clear description}
- **Risk**: {what happens if not fixed}
- **Fix**: {specific action}
- **Unlocks**: Fixing this reduces risk in {X} dependent modules

{repeat for all CRITICAL findings}

### ⚠️ Fix Before Next Release (High)

{same format, all HIGH findings sorted by fix-order algorithm}

---

## Module Reports

{For each module in review_order from modules.json:}

---

### Module {N}: {Module Name}

**Path**: `{path}` | **Files**: {count}

#### Scores

| Score | Value | Grade |
|-------|-------|-------|
| Overall | {n}/100 | {letter} |
| Bugs | {n}/100 | {letter} |
| Tech Debt | {n}/100 | {letter} |
| Documentation | {n}/100 | {letter} |

{If delta: show ▲▼ vs previous}

#### Summary

{2-3 sentences on the general state of this module}

#### Security Findings

{All CRITICAL + HIGH security findings for this module}
{Each finding format:}

**[{severity}] {title}**
- **File**: `{path}`, line {n}-{n}
- **CWE**: {if available} | **OWASP**: {if available}
- **Confidence**: {HIGH/MEDIUM/LOW} {if SAST-corroborated: "✓ confirmed by Semgrep"}
- **Issue**: {description}
- **Risk**: {impact}
- **Fix**: {specific recommendation}
```{language}
{fix_snippet if available}
```

{Medium/Low findings as a condensed table:}
| Severity | Title | File | Line |
|----------|-------|------|------|

#### Performance Findings

{Same format, filtered to category=PERFORMANCE}

#### Code Quality & Tech Debt

{Same format, filtered to is_tech_debt=true}

#### Dependency Vulnerabilities

{Table of OSV findings for this module's ecosystem}
| Package | Version | Vulnerability | Severity | Fix Version |
|---------|---------|---------------|----------|-------------|

#### Test Coverage Assessment

{Summary paragraph on test coverage quality}

#### Positive Observations

{Bullet list from positive_observations across both review JSONs}

#### Fix Order for This Module

{Ordered numbered list with rationale}
1. {Finding ID}: {title} — {reason for this position}

---

{end module, repeat for next}

---

## Appendix: Medium & Low Findings (All Modules)

{Condensed table of all MEDIUM/LOW findings not already shown}
| Module | Severity | Category | Title | File | Line |

---

## Appendix: Static Analysis Tool Summary

| Tool | Status | Findings | Notes |
|------|--------|----------|-------|
| Semgrep | ✅ ran / ⚠️ skipped | {n} findings | {version if available} |
| Gitleaks | ... | ... | ... |
| TruffleHog | ... | ... | ... |
| OSV-Scanner | ... | ... | ... |
| Lizard | ... | ... | ... |

---

*Report generated by code-review-toolkit. AI findings should be
verified by human reviewers before remediation. Static analysis
findings are deterministic but may include false positives.*
```

---

# SECTION 3: PROMPT TEMPLATES

## prompts/root_claude_md.md

```
You are a senior software architect conducting a pre-review analysis
of a backend codebase.

Your task is NOT to review the code. Your task is to:
1. Analyze the directory structure and file names below
2. Infer the purpose of each directory and key file
3. Group related files into logical "review modules"
4. Produce TWO outputs: root CLAUDE.md and modules.json

Each module must:
- Represent a cohesive unit of functionality
- Aim for 10-20 files max (split larger modules)
- Map to a real directory path in the repository

OUTPUT 1: Root CLAUDE.md

Use exactly this structure:

# CLAUDE.md — Project Root

## Project Overview
[1-3 sentences on type of app, inferred purpose, audience]

## Tech Stack
[Language, framework, DB, ORM, test framework, notable libraries]

## Architecture Pattern
[MVC / layered / hexagonal / microservices — infer from structure]

## Repository Structure
[Annotated directory tree — one line per major dir explaining its role]

## Review Modules
| # | Module Name | Path | Key Concern |
|---|-------------|------|-------------|
[one row per module]

## Cross-Cutting Concerns
[Logging, error handling, config/secrets, validation, auth checks]

## Recommended Review Order
[Ordered list, most foundational first, with one-line rationale each]

## Known Patterns & Conventions
[Infer from naming: e.g. routes→controllers→services→repos]

## What Claude Should NOT Review
[Generated code, vendor dirs, build artifacts]

---

OUTPUT 2: modules.json

Output valid JSON with exactly this schema:

{
  "repo_root": ".",
  "generated_at": "[ISO timestamp]",
  "review_order": [1, 2, 3, ...],
  "modules": [
    {
      "id": 1,
      "name": "Authentication",
      "path": "src/auth",
      "claude_md_path": "src/auth/CLAUDE.md",
      "description": "Handles login, JWT issuance and validation",
      "key_concerns": ["security", "token handling"],
      "depends_on": [],
      "depended_on_by": ["src/api", "src/middleware"],
      "file_patterns": ["src/auth/**/*"],
      "estimated_file_count": 8
    }
  ]
}

Rules:
- Every module MUST have a real path that exists in the repo
- review_order lists module IDs in recommended sequence
- depends_on and depended_on_by use directory paths
- No comments in the JSON — pure valid JSON only

---

Delimit your outputs EXACTLY as follows:

===== BEGIN CLAUDE.md =====
[content]
===== END CLAUDE.md =====

===== BEGIN modules.json =====
[content]
===== END modules.json =====

---

Repository structural snapshot:

[SNAPSHOT_CONTENT]
```

---

## prompts/module_claude_md.md

```
You are a senior software architect creating focused documentation
for a code review session.

You have already analyzed the full repository (root CLAUDE.md below).
Now create a CLAUDE.md for a single module. This file will be placed
in the module's directory and automatically loaded during review.

Generate using EXACTLY this structure:

# CLAUDE.md — [Module Name]

## Module Purpose
[2-4 sentences: what this module does, its role, what to understand before diving in]

## Internal Structure
[How responsibilities are divided internally. What calls what.]

## Key Files
[For each important file:]
- `filename.ext` — [one line: what it does and why it matters]

## Entry Points
[Where execution enters from outside. API endpoints, exports, event handlers.]

## External Dependencies
[Which other repo modules this imports from — be specific]

## Consumed By
[Which other modules call into this one]

## Data Flow
[How data moves: Request → validate → check permissions → query → transform → respond]

## Review Focus Areas

### Security
[Specific things to check: JWT expiry, input validation, auth enforcement]

### Performance
[N+1 patterns, missing pagination, unindexed fields, blocking ops]

### Error Handling
[Async error coverage, silent failures, error message exposure]

### Business Logic
[Edge cases, concurrent operations, atomic transactions]

### Test Coverage
[What's missing: edge cases, error paths, concurrent scenarios]

## Known Risks / Red Flags
[Patterns that would be especially dangerous in this module specifically]

## Conventions Specific to This Module
[Local patterns/decisions a reviewer needs to know]

---

DO NOT include any preamble, explanation, or markdown code fences.
Start directly with "# CLAUDE.md —"

---

Root CLAUDE.md:
[ROOT_CLAUDE_MD_CONTENT]

---

Module info:
Name: [MODULE_NAME]
Path: [MODULE_PATH]
Description: [MODULE_DESCRIPTION]
Key concerns: [KEY_CONCERNS]
Depends on: [DEPENDS_ON]
Depended on by: [DEPENDED_ON_BY]

Files in this module:
[FILE_LISTING]
```

---

## prompts/comprehensive_review.md

```
You are a senior software engineer and code reviewer.
Review a single backend module and return your findings as JSON.

IMPORTANT: Your entire response must be valid JSON. No preamble,
no explanation, no markdown code fences. Start with { and end with }.

The JSON must conform exactly to this schema:
{
  "module_id": number,
  "module_name": string,
  "review_type": "comprehensive",
  "model": string,
  "timestamp": ISO string,
  "scores": {
    "overall": number (0-100),
    "bug_score": number (0-100),
    "tech_debt_score": number (0-100),
    "documentation_score": number (0-100),
    "grade": "A"|"B"|"C"|"D"|"F"
  },
  "findings": [ FindingObject, ... ],
  "positive_observations": [ string, ... ],
  "summary": string,
  "fix_order": [ { "id": string, "reason": string }, ... ]
}

FindingObject schema:
{
  "id": "COMP-{NNN}",
  "title": string,
  "severity": "CRITICAL"|"HIGH"|"MEDIUM"|"LOW",
  "category": "SECURITY"|"PERFORMANCE"|"CODE_QUALITY"|"ERROR_HANDLING"|
               "BUSINESS_LOGIC"|"TEST_COVERAGE"|"DOCUMENTATION",
  "subcategory": string,
  "confidence": "HIGH"|"MEDIUM"|"LOW",
  "file": string,
  "line_start": number|null,
  "line_end": number|null,
  "description": string,
  "risk": string,
  "fix": string,
  "code_snippet": string|null,
  "fix_snippet": string|null,
  "is_bug": boolean,
  "is_tech_debt": boolean,
  "estimated_fix_effort": "LOW"|"MEDIUM"|"HIGH",
  "sast_corroborated": boolean,
  "sast_source": string|null
}

Review the module across ALL of these dimensions:

SECURITY: Injection vulnerabilities, broken auth, IDOR, missing
authorization, sensitive data exposure, hardcoded secrets, insecure
crypto, input validation gaps, OWASP Top 10 broadly.

CODE QUALITY: Readability, naming clarity, function length,
single-responsibility, DRY violations, dead code, magic numbers,
consistency with project conventions (from CLAUDE.md).

ERROR HANDLING: Unhandled rejections, silent catch blocks, error
details leaking to API responses, missing timeouts, no retry logic
where appropriate.

PERFORMANCE: N+1 queries, missing pagination, unindexed fields,
blocking ops, unnecessary re-computation, memory leaks, missing cache.

BUSINESS LOGIC: Inconsistencies with module purpose, unhandled edge
cases (nulls, empty arrays, concurrent requests), race conditions,
non-atomic operations, incorrect status codes.

TEST COVERAGE: Missing tests for critical paths, poor assertions,
untested error paths, problematic test data.

DOCUMENTATION: Missing/outdated comments on non-obvious logic,
missing docstrings, undocumented architectural decisions, FIXMEs
that should be tracked.

Scoring:
- Start at 100 for each score type
- CRITICAL: -15, HIGH: -8, MEDIUM: -3, LOW: -1
- Floor at 0
- Bug score: only is_bug=true findings
- Tech debt score: only is_tech_debt=true findings
- Documentation score: your direct assessment 0-100

If the SAST findings include something relevant to a finding you
identify, set sast_corroborated=true and cite the rule ID.
If SAST flagged something and you agree it is a real issue, include
it as a finding. If you disagree it is real (false positive), do NOT
include it.

Be specific. Cite file and line numbers. Include fix_snippet where
the fix is non-obvious. Do not pad findings with generic advice.

---

Root CLAUDE.md:
[ROOT_CLAUDE_MD_CONTENT]

Module CLAUDE.md:
[MODULE_CLAUDE_MD_CONTENT]

SAST findings for this module (Semgrep):
[SEMGREP_FINDINGS_JSON]

Complexity findings for this module (Lizard):
[LIZARD_FINDINGS_JSON]

OSV dependency vulnerabilities:
[OSV_FINDINGS_JSON]

Source files:
[SOURCE_FILE_CONTENTS]
```

---

## prompts/security_review.md

```
You are a senior application security engineer specializing in
backend API security and secure code review.

Review a single backend module for security vulnerabilities.
Return your findings as valid JSON ONLY.
No preamble, no explanation, no markdown code fences.

The JSON must conform exactly to this schema:
{
  "module_id": number,
  "module_name": string,
  "review_type": "security",
  "model": string,
  "timestamp": ISO string,
  "scores": {
    "security_score": number (0-100),
    "grade": "A"|"B"|"C"|"D"|"F"
  },
  "findings": [ SecurityFindingObject, ... ],
  "secrets_found": [ SecretObject, ... ],
  "dependency_vulnerabilities": [ DepVulnObject, ... ],
  "summary": string,
  "fix_order": [ { "id": string, "reason": string }, ... ]
}

SecurityFindingObject schema:
{
  "id": "SEC-{NNN}",
  "title": string,
  "severity": "CRITICAL"|"HIGH"|"MEDIUM"|"LOW",
  "category": "SECURITY",
  "subcategory": string,  // e.g. "sql_injection", "broken_auth", "idor"
  "cwe": string|null,     // e.g. "CWE-89"
  "owasp": string|null,   // e.g. "A03:2021"
  "confidence": "HIGH"|"MEDIUM"|"LOW",
  "file": string,
  "line_start": number|null,
  "line_end": number|null,
  "description": string,
  "risk": string,
  "fix": string,
  "code_snippet": string|null,
  "fix_snippet": string|null,
  "sast_corroborated": boolean,
  "sast_source": string|null,
  "verified_by_sast": boolean  // true only if SAST independently found this
}

SecretObject schema:
{
  "type": string,
  "file": string,
  "line": number|null,
  "description": "REDACTED — do not reproduce secret value",
  "severity": "CRITICAL"|"HIGH",
  "source": "gitleaks"|"trufflehog"|"manual"
}

DepVulnObject schema:
{
  "package": string,
  "version": string,
  "vulnerability_id": string,
  "severity": "CRITICAL"|"HIGH"|"MEDIUM"|"LOW",
  "fix_version": string|null,
  "description": string,
  "source": "osv-scanner"|"npm-audit"|"pip-audit"
}

Check specifically for:
INJECTION: SQL, NoSQL, LDAP, command, template, XPath injection
AUTH/SESSION: Broken authentication, missing token expiry, session fixation,
  JWT alg=none, JWT secret hardcoded, missing revocation
ACCESS CONTROL: IDOR, missing authorization checks on object access,
  privilege escalation, path traversal
SENSITIVE DATA: Logging of PII/secrets, error messages leaking internals,
  unencrypted sensitive storage, insecure transport
CRYPTO: Weak algorithms (MD5/SHA1 for passwords), improper key handling,
  insufficient entropy, hardcoded IVs/salts
INPUT VALIDATION: Missing sanitization, type coercion vulnerabilities,
  mass assignment, prototype pollution
RATE LIMITING: Missing rate limits on auth, password reset, OTP endpoints
SUPPLY CHAIN: Known CVEs in direct and transitive dependencies

For the SAST findings provided: if Semgrep, Gitleaks, or TruffleHog
flagged something, include it as a finding if you agree it is real.
If you believe it is a false positive, OMIT it (don't include false
positives). Set sast_corroborated=true when SAST and your analysis
agree on the same issue.

NEVER reproduce the actual value of a detected secret. Always redact.

Scoring:
- CRITICAL: -15, HIGH: -8, MEDIUM: -3, LOW: -1, floor at 0
- Grade: 90+=A, 75-89=B, 60-74=C, 40-59=D, 0-39=F

---

Root CLAUDE.md:
[ROOT_CLAUDE_MD_CONTENT]

Module CLAUDE.md:
[MODULE_CLAUDE_MD_CONTENT]

Semgrep SAST findings:
[SEMGREP_FINDINGS_JSON]

Gitleaks findings:
[GITLEAKS_FINDINGS_JSON]

TruffleHog findings:
[TRUFFLEHOG_FINDINGS_JSON]

OSV dependency vulnerabilities:
[OSV_FINDINGS_JSON]

Source files:
[SOURCE_FILE_CONTENTS]
```

---

## prompts/synthesis.md

```
You are a principal engineer and security architect synthesizing the
results of a comprehensive automated code review into a final report.

You have been given:
- Root CLAUDE.md (project-level context)
- Per-module comprehensive review JSON files
- Per-module security review JSON files
- modules.json (module metadata and review order)
- Selected documentation files (README, architecture docs, etc.)
- (Optional) Previous report JSON for delta scoring

Your task is to produce a single, authoritative Markdown report.

SCORING RULES (apply exactly):

Per-module overall score:
  Start at 100
  CRITICAL finding: -15
  HIGH finding: -8
  MEDIUM finding: -3
  LOW finding: -1
  Floor: 0
  Grade: 90+=A, 75-89=B, 60-74=C, 40-59=D, 0-39=F

Per-module bug score: same formula, only is_bug=true findings
Per-module tech debt score: same formula, only is_tech_debt=true
Per-module documentation score: use documentation_score from
  comprehensive review JSON directly

Codebase-wide score:
  Weighted average: sum(module_score × module_file_count) / sum(all_file_counts)
  Apply same grade bands

FIX-ORDER ALGORITHM (apply to Top Recommendations section):
1. Collect all CRITICAL and HIGH findings across all modules
2. Sort by:
   a. Severity (CRITICAL before HIGH)
   b. Number of modules that depend_on this module (more = higher priority)
   c. estimated_fix_effort (LOW effort = prioritize — get quick wins)
3. For each finding, note which dependent modules benefit from fixing it

DOCUMENTATION READING INSTRUCTIONS:
The documentation provided is CONTEXT only — it may help you
understand the intended architecture, known limitations, or design
decisions. It is NOT a source of code findings. Use it to:
- Understand what the application is supposed to do
- Identify if findings represent deviations from stated intent
- Add relevant context to the Codebase Overview section
Do NOT cite docs as a source of findings. Do NOT quote docs extensively.

REPORT STRUCTURE:
Produce the report in EXACTLY this order:

1. Title: # {Codebase Name} — Quality Report
2. Generation metadata line (date, tool version)
3. Horizontal rule
4. ## Final Score: {n}/100 — Grade {letter}
   Scores table (Overall, Security, Bug Density, Tech Debt, Documentation)
   Delta table if previous report provided
5. Horizontal rule
6. ## Codebase Overview (2-4 paragraphs)
7. Horizontal rule
8. ## Top Recommendations
   ### 🚨 Fix Immediately (Critical) — all CRITICAL findings
   ### ⚠️ Fix Before Next Release (High) — all HIGH findings sorted by fix-order
9. Horizontal rule
10. ## Module Reports (repeat for each module in review_order)
11. Horizontal rule
12. ## Appendix: Medium & Low Findings
13. ## Appendix: Static Analysis Tool Summary

Full structure specification is in Section 3 of the toolkit spec.

TONE GUIDELINES:
- Be direct and specific. Engineers are reading this.
- Do not soften findings. If it's critical, say it's critical.
- Do not pad positive observations. Only include genuine strengths.
- Use precise language: not "may be vulnerable" but
  "is vulnerable to SQL injection via the search parameter on line 47"
- Every finding must have a specific, actionable fix.

---

Root CLAUDE.md:
[ROOT_CLAUDE_MD_CONTENT]

modules.json:
[MODULES_JSON_CONTENT]

Documentation (selective):
[DOCS_CONTENT]

Previous report summary (if provided):
[PREVIOUS_REPORT_SUMMARY]

Comprehensive review results (all modules):
[ALL_COMPREHENSIVE_REVIEW_JSON]

Security review results (all modules):
[ALL_SECURITY_REVIEW_JSON]
```

---

# SECTION 4: AGENT DEFINITIONS (.claude/agents/)

## .claude/agents/architect.md

```markdown
---
name: architect
description: Generates CLAUDE.md documentation files from repository
  structure. Use for: generating root CLAUDE.md with modules.json,
  generating per-module CLAUDE.md files from file listings.
tools: Read, Write, Bash
model: claude-sonnet-4-6
---

You are a senior software architect whose job is to produce clear,
accurate documentation that will guide code reviewers.

Your outputs are consumed by automated pipelines. Format matters.
Follow the template provided in the prompt exactly.

When generating CLAUDE.md files:
- Be specific, not generic. Infer from actual file names.
- Keep it dense and useful, not padded with boilerplate.
- The "Known Risks / Red Flags" section is the most important —
  think hard about what is specifically dangerous in THIS module.
- Do not invent functionality that isn't evidenced by the file names.
```

## .claude/agents/comprehensive-reviewer.md

```markdown
---
name: comprehensive-reviewer
description: Performs broad code quality review of a single module.
  Covers: code quality, performance, error handling, business logic,
  test coverage, documentation. Returns structured JSON findings.
tools: Read
model: claude-sonnet-4-6
---

You are a senior software engineer conducting a thorough code review.

Your output must be valid JSON that exactly matches the schema in
the prompt. No preamble. No explanation. No code fences. Just JSON.

Review standards:
- Be specific. Every finding needs a file, a line, a fix.
- Only report real issues. Avoid false positives.
- The confidence field must reflect your actual certainty.
- LOW confidence findings should only be included if severity is HIGH+.
- Positive observations must be genuine strengths, not filler.
- Fix order must account for dependency — fix foundational issues first.
```

## .claude/agents/security-reviewer.md

```markdown
---
name: security-reviewer
description: Performs deep security-focused review of a single module.
  Specializes in: OWASP Top 10, injection, auth/authz, secrets,
  dependency vulnerabilities. Returns structured JSON findings.
  Uses Opus for maximum security finding accuracy.
tools: Read
model: claude-opus-4-6
---

You are a senior application security engineer specializing in
backend API security.

Your output must be valid JSON matching the schema in the prompt.
No preamble. No explanation. No code fences. Just JSON.

Security review standards:
- Assume hostile input. Assume attackers will find your findings.
- Use CWE and OWASP identifiers wherever they apply.
- Distinguish between theoretical and practically exploitable issues.
- HIGH confidence = you are certain this is exploitable.
- MEDIUM confidence = likely vulnerable, needs verification.
- LOW confidence = possible attack vector, worth noting.
- NEVER include actual secret values. Always redact.
- When SAST corroborates a finding, set verified_by_sast=true.
  This significantly increases finding credibility.
- False positives from SAST should be silently omitted.
```

## .claude/agents/synthesis.md

```markdown
---
name: synthesis
description: Synthesizes all module review JSON files into a single
  comprehensive final report. Computes scores, runs fix-order
  algorithm, produces final Markdown report.
tools: Read, Write
model: claude-opus-4-6
---

You are a principal engineer and security architect writing the
definitive quality report for a codebase.

Your audience: CTOs, lead engineers, and developers who need to
make prioritization decisions based on your report.

Report standards:
- The report must be immediately actionable.
- Scores must be computed EXACTLY per the formula in the prompt.
- The fix-order algorithm must account for inter-module dependencies.
- Every critical and high finding must appear in Top Recommendations.
- Do not duplicate findings — each appears once at its highest-severity location.
- Be direct. Engineers do not need softening language.
- The codebase overview must read as if written by someone who
  understands what this application does and who uses it.
```

---

# SECTION 5: CONFIGURATION FILE

## config/toolkit.conf

```bash
# code-review-toolkit configuration
# These are defaults. All can be overridden via CLI flags.

# Models
MODEL_DEFAULT="claude-sonnet-4-6"
MODEL_SECURITY="claude-opus-4-6"
MODEL_SYNTHESIS="claude-opus-4-6"

# Parallelism
PARALLEL_LIMIT=4                  # max concurrent Claude agents
STATIC_PARALLEL=5                 # static tools always run in parallel

# Context limits
DOCS_LIMIT_LINES=300              # max lines from any doc file
MAX_FILES_PER_MODULE=25           # warn if module exceeds this
MAX_SOURCE_TOKENS_PER_REVIEW=80000 # approx token budget for source code

# Static tool thresholds
LIZARD_CCN_THRESHOLD=10           # cyclomatic complexity warning
LIZARD_LENGTH_THRESHOLD=100       # function length warning
LIZARD_PARAMS_THRESHOLD=6         # parameter count warning

# Scoring
SCORE_CRITICAL_DEDUCTION=15
SCORE_HIGH_DEDUCTION=8
SCORE_MEDIUM_DEDUCTION=3
SCORE_LOW_DEDUCTION=1

# Reporting
REPORT_INCLUDE_LOW_IN_MAIN=false  # include LOW findings in module section
                                   # (always in appendix)

# Tool paths (auto-detected if not set)
SEMGREP_BIN="semgrep"
GITLEAKS_BIN="gitleaks"
TRUFFLEHOG_BIN="trufflehog"
OSV_SCANNER_BIN="osv-scanner"
LIZARD_BIN="lizard"
```

---

# SECTION 6: MASTER SCRIPT LOGIC

## master_review.sh high-level pseudocode

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Parse arguments (REPO_PATH + all option flags)
# 2. Load config/toolkit.conf
# 3. Validate: repo exists, claude CLI present, jq present
# 4. Generate RUN_ID = $(date +%Y%m%d_%H%M%S)
# 5. Create output/{RUN_ID}/ directory structure
# 6. Print banner with config summary

# Phase 1
echo "Phase 1/6: Generating repository snapshot..."
scripts/01_generate_snapshot.sh "$REPO_PATH" \
  "$OUTPUT_DIR/$RUN_ID/snapshot/repo_snapshot.txt"

# Phase 2
echo "Phase 2/6: Generating root CLAUDE.md and module manifest..."
scripts/02_root_claude_md.sh \
  "$REPO_PATH" \
  "$OUTPUT_DIR/$RUN_ID/snapshot/repo_snapshot.txt" \
  "$MODEL_DEFAULT"
# This writes CLAUDE.md and modules.json to REPO ROOT

# Phase 3
echo "Phase 3/6: Generating per-module CLAUDE.md files (parallel)..."
scripts/03_module_claude_mds.sh \
  "$REPO_PATH" \
  "$MODEL_DEFAULT" \
  "$PARALLEL_LIMIT"

# Phase 4 (skip if --skip-static)
echo "Phase 4/6: Running static analysis tools (parallel)..."
scripts/04_static_analysis.sh \
  "$REPO_PATH" \
  "$OUTPUT_DIR/$RUN_ID/static" \
  "$SKIP_STATIC" \
  "$SKIP_SECRETS"

# Phase 5
echo "Phase 5/6: Running AI review agents (parallel)..."
scripts/05_ai_review.sh \
  "$REPO_PATH" \
  "$OUTPUT_DIR/$RUN_ID/static" \
  "$OUTPUT_DIR/$RUN_ID/reviews" \
  "$MODEL_DEFAULT" \
  "$MODEL_SECURITY" \
  "$PARALLEL_LIMIT"

# Phase 6
echo "Phase 6/6: Synthesizing final report..."
REPORT_PATH="$OUTPUT_DIR/${RUN_ID}/${CODEBASE_NAME}_report.md"
scripts/06_synthesis.sh \
  "$REPO_PATH" \
  "$OUTPUT_DIR/$RUN_ID/reviews" \
  "$REPORT_PATH" \
  "$MODEL_SYNTHESIS" \
  "$DOCS_LIMIT_LINES" \
  "${PREVIOUS_REPORT:-}"

echo ""
echo "✅ Report complete: $REPORT_PATH"
echo "   Score: {score}/100 — Grade {letter}"
echo "   Critical findings: {n}"
echo "   High findings: {n}"
```

---

# SECTION 7: BOOTSTRAP SCRIPT

## bootstrap.sh

The bootstrap script installs all dependencies and validates the
environment. Run once before first use.

```bash
#!/usr/bin/env bash
# Usage: ./bootstrap.sh

# Check: claude CLI
# Check: jq
# Check: Python 3 (for semgrep, lizard)

# Install semgrep: pip install semgrep --break-system-packages
# Install lizard: pip install lizard --break-system-packages
# Install pip-audit: pip install pip-audit --break-system-packages

# Install gitleaks:
#   macOS: brew install gitleaks
#   Linux: download binary from https://github.com/gitleaks/gitleaks/releases

# Install trufflehog:
#   macOS: brew install trufflehog
#   Linux: download from https://github.com/trufflesecurity/trufflehog/releases

# Install osv-scanner:
#   macOS: brew install osv-scanner
#   Linux: download from https://github.com/google/osv-scanner/releases

# Install tree (optional, for better snapshot):
#   macOS: brew install tree
#   Linux: apt install tree / yum install tree

# Verify all tools and print version table
echo "Tool versions:"
echo "  claude:       $(claude --version 2>/dev/null || echo 'NOT FOUND')"
echo "  semgrep:      $(semgrep --version 2>/dev/null || echo 'NOT FOUND — run: pip install semgrep')"
echo "  lizard:       $(lizard --version 2>/dev/null || echo 'NOT FOUND — run: pip install lizard')"
echo "  gitleaks:     $(gitleaks version 2>/dev/null || echo 'NOT FOUND — see bootstrap.sh')"
echo "  trufflehog:   $(trufflehog --version 2>/dev/null || echo 'NOT FOUND — see bootstrap.sh')"
echo "  osv-scanner:  $(osv-scanner --version 2>/dev/null || echo 'NOT FOUND — see bootstrap.sh')"
echo "  jq:           $(jq --version 2>/dev/null || echo 'NOT FOUND — run: brew install jq')"
echo "  tree:         $(tree --version 2>/dev/null || echo 'NOT FOUND (optional)')"
```

---

# SECTION 8: README.md CONTENT

## README.md

```markdown
# code-review-toolkit

> Automated AI + static analysis codebase quality scanner.
> Produces a comprehensive, module-first quality report in one command.

## What It Does

1. Scans your repository structure to map modules (no code reading yet)
2. Generates CLAUDE.md context files for the root and each module
3. Runs static analysis: Semgrep (SAST), Gitleaks + TruffleHog (secrets),
   OSV-Scanner (dependencies), Lizard (complexity)
4. Spawns parallel Claude agents per module:
   - Comprehensive review (Sonnet): quality, performance, error handling
   - Security review (Opus): vulnerabilities, secrets, CVEs
5. Synthesis agent (Opus) reads all findings and produces final report

## Quick Start

```bash
# 1. One-time setup
./bootstrap.sh

# 2. Run against your repo
./master_review.sh /path/to/your/backend

# 3. Open the report
open ./output/*/reports/*_report.md
```

## Output

A single Markdown report containing:
- Final quality score (0-100, A-F grade) for the whole codebase
- Per-module scores: overall, bugs, tech debt, documentation
- All critical/high findings with specific files, lines, and fixes
- Cross-module fix-order prioritization
- Dependency vulnerability table
- Complexity hot spots

## Requirements

- Claude Code CLI (`claude` command)
- Python 3.10+ (for semgrep, lizard)
- jq
- Optional but recommended: gitleaks, trufflehog, osv-scanner

Run `./bootstrap.sh` to install everything.

## Options

See `./master_review.sh --help` for full options.

Key flags:
- `--name "My App"` — codebase name for report title
- `--model-security claude-opus-4-6` — model for security agent
- `--resume` — continue after partial failure
- `--previous-report path` — show delta vs previous scan
- `--skip-static` — Claude only, no static tools (faster)

## Cost Estimate

For a 6-module codebase (~500 files):
- ~13 Claude agent invocations
- ~2-3M tokens total (mostly Sonnet, a few Opus)
- Approximate cost: $5-15 depending on models chosen
- Time: ~12-16 minutes with full parallelism

## Architecture

See ARCHITECTURE.md for the full pipeline design.
```

---

# SECTION 9: KEY IMPLEMENTATION NOTES FOR AGENTS

These are critical details that may not be obvious from the structure:

## 1. Static findings must be filtered to module paths
When assembling the prompt for a module review, filter semgrep/lizard
findings to only include those where the `path` field starts with or
matches the module's path. OSV findings are global (dependency-level)
and should be included in every module review.

## 2. Source file contents have a token budget
If a module has many files, concatenating all of them may exceed Claude's
effective context. Apply this logic:
- Estimate tokens: ~4 chars per token
- If total source exceeds MAX_SOURCE_TOKENS_PER_REVIEW (default 80000):
  - Prioritize: auth files > controller files > service files > util files
  - Include as many as fit, note how many were omitted in the prompt

## 3. JSON output validation
Both review agents produce JSON. Validate with `jq empty`. If the output
fails validation:
- First try: extract JSON from the response (sometimes Claude adds a
  small preamble despite instructions)
  ```bash
  # Extract JSON starting from first { to last }
  python3 -c "
  import sys, re
  content = sys.stdin.read()
  match = re.search(r'\{.*\}', content, re.DOTALL)
  if match: print(match.group())
  "
  ```
- If still invalid: retry the agent once
- If still invalid after retry: write an error JSON:
  ```json
  {"error": "agent_output_invalid_json", "module_id": N, "raw": "..."}
  ```
  The synthesis agent should handle this gracefully.

## 4. Gitleaks --no-git flag
If the directory being scanned is NOT a git repository, use `--no-git`.
If it IS a git repo, omit it to also scan git history (much more thorough
for secret detection). Detect with: `git -C "$REPO_PATH" rev-parse 2>/dev/null`

## 5. Progress file format
The .claude_review_progress file uses a simple key=value format:
```
# Module CLAUDE.md generation progress
# Generated: 2026-02-27T10:00:00
module_1=DONE # Authentication
module_2=DONE # Database Layer
module_3=FAILED # API Routes
```
The --resume flag reads this and skips DONE entries.

## 6. Run ID
The RUN_ID is generated once at the start of master_review.sh:
```bash
RUN_ID="$(date +%Y%m%d_%H%M%S)_$(basename $REPO_PATH)"
```
Example: `20260227_103045_my-backend`
All output for a run lives under output/{RUN_ID}/

## 7. Synthesis docs reading
Read docs in priority order, stop when approaching token budget.
Never read actual .env files. .env.example is fine (shows expected
env vars without actual values). This is important — .env files can
contain live credentials.

## 8. Parallelism and rate limiting
- Sleep 2 seconds between spawning each Claude agent
- This avoids hitting the API rate limit while still running in parallel
- Static tools have no rate limit concern — run all 5 simultaneously

## 9. The --previous-report flag
If provided, the synthesis agent receives a summary extracted from the
previous report's JSON data file:
```bash
# Extract summary from previous JSON report
jq '{
  date: .generated_at,
  final_score: .scores.overall,
  module_scores: [.modules[] | {name, score: .scores.overall}]
}' "$PREVIOUS_REPORT" > /tmp/prev_summary.json
```
The synthesis prompt includes this as "Previous report summary".

## 10. Report data JSON
In addition to the Markdown report, the synthesis agent should also
output a machine-readable JSON version of the scores for future
--previous-report comparisons. This should be saved alongside the
Markdown as `{report_name}_data.json`.

---

# SECTION 10: FILES EACH AGENT SHOULD CREATE

## Agent A should create:
- master_review.sh
- scripts/01_generate_snapshot.sh
- scripts/02_root_claude_md.sh
- README.md
- bootstrap.sh

## Agent B should create:
- scripts/03_module_claude_mds.sh
- scripts/04_static_analysis.sh
- config/toolkit.conf

## Agent C should create:
- scripts/05_ai_review.sh
- scripts/06_synthesis.sh

## Agent D should create:
- prompts/root_claude_md.md
- prompts/module_claude_md.md
- prompts/comprehensive_review.md
- prompts/security_review.md
- prompts/synthesis.md
- .claude/agents/architect.md
- .claude/agents/comprehensive-reviewer.md
- .claude/agents/security-reviewer.md
- .claude/agents/synthesis.md

## All agents should be aware of:
- The full directory structure in Section 0
- The JSON schemas in Section 2 (for review outputs)
- The report structure in Section 2 (for synthesis output)
- The token budget and validation logic in Section 9

---
END OF SPECIFICATION
---
