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
