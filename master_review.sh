#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./master_review.sh <repo_path> [OPTIONS]

Options:
  --name NAME               Human-readable codebase name for report
  --output DIR              Output root directory (default: ./output)
  --model-default MODEL     Model for non-security agents
  --model-security MODEL    Model for security agents
  --model-synthesis MODEL   Model for synthesis agent
  --skip-static             Skip static analysis tools
  --skip-secrets            Skip secret scanning
  --resume                  Resume from most recent run for this repo
  --previous-report PATH    Prior report_data.json path for delta context
  --docs-limit LINES        Max lines from any single doc file
  --parallel-limit N        Max concurrent Claude agents
  --only-phase N            Run only phase N (1-6)
  --dry-run                 Print commands without executing
  --help                    Show this help
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
shift

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

REPO_PATH="$(cd "$REPO_PATH" && pwd -P)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$SCRIPT_DIR"
CONFIG_PATH="$TOOLKIT_ROOT/config/toolkit.conf"

# Defaults before config load
MODEL_DEFAULT="claude-sonnet-4-6"
MODEL_SECURITY="claude-opus-4-6"
MODEL_SYNTHESIS="claude-opus-4-6"
PARALLEL_LIMIT=4
DOCS_LIMIT_LINES=300
OUTPUT_DIR="$TOOLKIT_ROOT/output"
SKIP_STATIC=false
SKIP_SECRETS=false
RESUME=false
PREVIOUS_REPORT=""
ONLY_PHASE=""
DRY_RUN=false

if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
fi

CODEBASE_NAME="$(basename "$REPO_PATH")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -lt 2 ]] && { echo "Error: --name requires a value" >&2; exit 2; }
      CODEBASE_NAME="$2"
      shift 2
      ;;
    --output)
      [[ $# -lt 2 ]] && { echo "Error: --output requires a value" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --model-default)
      [[ $# -lt 2 ]] && { echo "Error: --model-default requires a value" >&2; exit 2; }
      MODEL_DEFAULT="$2"
      shift 2
      ;;
    --model-security)
      [[ $# -lt 2 ]] && { echo "Error: --model-security requires a value" >&2; exit 2; }
      MODEL_SECURITY="$2"
      shift 2
      ;;
    --model-synthesis)
      [[ $# -lt 2 ]] && { echo "Error: --model-synthesis requires a value" >&2; exit 2; }
      MODEL_SYNTHESIS="$2"
      shift 2
      ;;
    --skip-static)
      SKIP_STATIC=true
      shift
      ;;
    --skip-secrets)
      SKIP_SECRETS=true
      shift
      ;;
    --resume)
      RESUME=true
      shift
      ;;
    --previous-report)
      [[ $# -lt 2 ]] && { echo "Error: --previous-report requires a value" >&2; exit 2; }
      PREVIOUS_REPORT="$2"
      shift 2
      ;;
    --docs-limit)
      [[ $# -lt 2 ]] && { echo "Error: --docs-limit requires a value" >&2; exit 2; }
      DOCS_LIMIT_LINES="$2"
      shift 2
      ;;
    --parallel-limit)
      [[ $# -lt 2 ]] && { echo "Error: --parallel-limit requires a value" >&2; exit 2; }
      PARALLEL_LIMIT="$2"
      shift 2
      ;;
    --only-phase)
      [[ $# -lt 2 ]] && { echo "Error: --only-phase requires a value" >&2; exit 2; }
      ONLY_PHASE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$PARALLEL_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --parallel-limit must be a positive integer: $PARALLEL_LIMIT" >&2
  exit 2
fi

if ! [[ "$DOCS_LIMIT_LINES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --docs-limit must be a positive integer: $DOCS_LIMIT_LINES" >&2
  exit 2
fi

if [[ -n "$ONLY_PHASE" ]] && ! [[ "$ONLY_PHASE" =~ ^[1-6]$ ]]; then
  echo "Error: --only-phase must be one of 1..6: $ONLY_PHASE" >&2
  exit 2
fi

if [[ -n "$PREVIOUS_REPORT" && ! -f "$PREVIOUS_REPORT" ]]; then
  echo "Error: --previous-report file not found: $PREVIOUS_REPORT" >&2
  exit 2
fi

sanitize_name() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  value="$(printf "%s" "$value" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g')"
  [[ -z "$value" ]] && value="codebase"
  printf "%s" "$value"
}

module_output_relpath() {
  local module_path="$1"
  if [[ "$module_path" == "." ]]; then
    printf "CLAUDE.md"
  else
    module_path="${module_path%/}"
    printf "%s/CLAUDE.md" "$module_path"
  fi
}

should_run_phase() {
  local phase="$1"
  if [[ -n "$ONLY_PHASE" ]]; then
    [[ "$phase" == "$ONLY_PHASE" ]]
    return
  fi
  return 0
}

OUTPUT_DIR_ABS="$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR_ABS"

REPO_BASENAME="$(basename "$REPO_PATH")"
RUN_ID=""
RESUME_ACTIVE=false
if [[ "$RESUME" == "true" ]]; then
  while IFS= read -r candidate_run; do
    [[ -z "${candidate_run:-}" ]] && continue
    candidate_root="$OUTPUT_DIR_ABS/$candidate_run"

    if [[ -f "$candidate_root/repo_path.txt" ]]; then
      candidate_repo="$(cat "$candidate_root/repo_path.txt")"
      if [[ "$candidate_repo" == "$REPO_PATH" ]]; then
        RUN_ID="$candidate_run"
        RESUME_ACTIVE=true
        break
      fi
      continue
    fi

    snapshot_path="$candidate_root/snapshot/repo_snapshot.txt"
    if [[ -f "$snapshot_path" ]]; then
      snapshot_repo="$(awk -F': ' '/^Repository: /{print $2; exit}' "$snapshot_path")"
      if [[ -n "${snapshot_repo:-}" ]]; then
        snapshot_repo_abs=""
        if [[ -d "$snapshot_repo" ]]; then
          snapshot_repo_abs="$(cd "$snapshot_repo" && pwd -P)"
        fi
        if [[ "$snapshot_repo" == "$REPO_PATH" || "$snapshot_repo_abs" == "$REPO_PATH" ]]; then
          RUN_ID="$candidate_run"
          RESUME_ACTIVE=true
          break
        fi
      fi
    fi
  done < <(
    find "$OUTPUT_DIR_ABS" -mindepth 1 -maxdepth 1 -type d -name "*_${REPO_BASENAME}" -printf '%f\n' \
      | sort -r
  )
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date +%Y%m%d_%H%M%S)_${REPO_BASENAME}"
fi

RUN_ROOT="$OUTPUT_DIR_ABS/$RUN_ID"
SNAPSHOT_DIR="$RUN_ROOT/snapshot"
STATIC_DIR="$RUN_ROOT/static"
REVIEWS_DIR="$RUN_ROOT/reviews"
REPORTS_DIR="$RUN_ROOT/reports"
SNAPSHOT_PATH="$SNAPSHOT_DIR/repo_snapshot.txt"

SAFE_CODEBASE_NAME="$(sanitize_name "$CODEBASE_NAME")"
REPORT_TIMESTAMP="${RUN_ID:0:15}"
REPORT_PATH_MD="$REPORTS_DIR/${REPORT_TIMESTAMP}_${SAFE_CODEBASE_NAME}_report.md"
REPORT_DATA_PATH="${REPORT_PATH_MD%.md}_data.json"

mkdir -p "$SNAPSHOT_DIR" "$STATIC_DIR" "$REVIEWS_DIR" "$REPORTS_DIR"
printf '%s\n' "$REPO_PATH" > "$RUN_ROOT/repo_path.txt"

run_cmd() {
  local description="$1"
  shift
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $description"
    printf '[dry-run]   '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  echo "$description"
  "$@"
}

phase1_done() {
  [[ -f "$SNAPSHOT_PATH" ]]
}

phase2_done() {
  [[ -f "$REPO_PATH/CLAUDE.md" && -f "$REPO_PATH/modules.json" ]]
}

phase3_done() {
  if [[ ! -f "$REPO_PATH/modules.json" ]]; then
    return 1
  fi
  local module_output_rel
  while IFS= read -r module_output_rel; do
    [[ -z "$module_output_rel" ]] && continue
    if [[ "$module_output_rel" == /* ]]; then
      return 1
    fi
    if [[ ! -f "$REPO_PATH/$module_output_rel" ]]; then
      return 1
    fi
  done < <(jq -r '.modules[].claude_md_path' "$REPO_PATH/modules.json")
  return 0
}

phase4_done() {
  [[ -f "$STATIC_DIR/semgrep.json" ]] &&
  [[ -f "$STATIC_DIR/gitleaks.json" ]] &&
  [[ -f "$STATIC_DIR/trufflehog.json" ]] &&
  [[ -f "$STATIC_DIR/osv.json" ]] &&
  [[ -f "$STATIC_DIR/lizard.json" ]]
}

phase5_done() {
  if [[ ! -f "$REPO_PATH/modules.json" ]]; then
    return 1
  fi
  local module_id module_name safe_name
  while IFS=$'\t' read -r module_id module_name; do
    safe_name="$(sanitize_name "$module_name")"
    [[ -f "$REVIEWS_DIR/comprehensive_${module_id}_${safe_name}.json" ]] || return 1
    [[ -f "$REVIEWS_DIR/security_${module_id}_${safe_name}.json" ]] || return 1
  done < <(jq -r '.modules[] | "\(.id)\t\(.name)"' "$REPO_PATH/modules.json")
  return 0
}

phase6_done() {
  local latest_report_name
  local latest_report
  local latest_data

  latest_report_name="$(
    find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type f -name '*_report.md' -printf '%f\n' \
      | sort \
      | tail -n 1 || true
  )"
  if [[ -z "${latest_report_name:-}" ]]; then
    return 1
  fi

  latest_report="$REPORTS_DIR/$latest_report_name"
  latest_data="${latest_report%.md}_data.json"
  if [[ ! -f "$latest_data" ]]; then
    return 1
  fi

  REPORT_PATH_MD="$latest_report"
  REPORT_DATA_PATH="$latest_data"
  return 0
}

echo "Code Review Toolkit"
echo "  Repo: $REPO_PATH"
echo "  Run ID: $RUN_ID"
echo "  Run root: $RUN_ROOT"
echo "  Models: default=$MODEL_DEFAULT security=$MODEL_SECURITY synthesis=$MODEL_SYNTHESIS"
echo "  Parallel limit: $PARALLEL_LIMIT"
echo "  skip_static=$SKIP_STATIC skip_secrets=$SKIP_SECRETS resume=$RESUME(resolved=$RESUME_ACTIVE) dry_run=$DRY_RUN"
if [[ "$RESUME" == "true" && "$RESUME_ACTIVE" != "true" ]]; then
  echo "  Resume note: no matching prior run found for this repo path; starting a new run."
fi

if should_run_phase 1; then
  if [[ "$RESUME_ACTIVE" == "true" && -z "$ONLY_PHASE" ]] && phase1_done; then
    echo "Phase 1/6: snapshot already exists; skipping due to --resume"
  else
    run_cmd "Phase 1/6: Generating repository snapshot..." \
      "$TOOLKIT_ROOT/scripts/01_generate_snapshot.sh" \
      "$REPO_PATH" \
      "$SNAPSHOT_PATH"
  fi
fi

if should_run_phase 2; then
  if [[ "$RESUME_ACTIVE" == "true" && -z "$ONLY_PHASE" ]] && phase2_done; then
    echo "Phase 2/6: root artifacts already exist; skipping due to --resume"
  else
    run_cmd "Phase 2/6: Generating root CLAUDE.md and modules.json..." \
      "$TOOLKIT_ROOT/scripts/02_root_claude_md.sh" \
      "$REPO_PATH" \
      "$SNAPSHOT_PATH" \
      "$MODEL_DEFAULT"
  fi
fi

if should_run_phase 3; then
  if [[ "$RESUME_ACTIVE" == "true" && -z "$ONLY_PHASE" ]] && phase3_done; then
    echo "Phase 3/6: module CLAUDE.md files already exist; skipping due to --resume"
  else
    run_cmd "Phase 3/6: Generating per-module CLAUDE.md files..." \
      "$TOOLKIT_ROOT/scripts/03_module_claude_mds.sh" \
      "$REPO_PATH" \
      "$MODEL_DEFAULT" \
      "$PARALLEL_LIMIT"
  fi
fi

if should_run_phase 4; then
  if [[ "$RESUME_ACTIVE" == "true" && -z "$ONLY_PHASE" ]] && phase4_done; then
    echo "Phase 4/6: static artifacts already exist; skipping due to --resume"
  else
    run_cmd "Phase 4/6: Running static analysis tools..." \
      "$TOOLKIT_ROOT/scripts/04_static_analysis.sh" \
      "$REPO_PATH" \
      "$STATIC_DIR" \
      "$SKIP_STATIC" \
      "$SKIP_SECRETS"
  fi
fi

if should_run_phase 5; then
  if [[ "$RESUME_ACTIVE" == "true" && -z "$ONLY_PHASE" ]] && phase5_done; then
    echo "Phase 5/6: review JSON outputs already exist; skipping due to --resume"
  else
    run_cmd "Phase 5/6: Running AI review agents..." \
      "$TOOLKIT_ROOT/scripts/05_ai_review.sh" \
      "$REPO_PATH" \
      "$STATIC_DIR" \
      "$REVIEWS_DIR" \
      "$MODEL_DEFAULT" \
      "$MODEL_SECURITY" \
      "$PARALLEL_LIMIT"
  fi
fi

if should_run_phase 6; then
  if [[ "$RESUME_ACTIVE" == "true" && -z "$ONLY_PHASE" ]] && phase6_done; then
    echo "Phase 6/6: report artifacts already exist; skipping due to --resume"
  else
    run_cmd "Phase 6/6: Synthesizing final report..." \
      "$TOOLKIT_ROOT/scripts/06_synthesis.sh" \
      "$REPO_PATH" \
      "$REVIEWS_DIR" \
      "$REPORT_PATH_MD" \
      "$MODEL_SYNTHESIS" \
      "$DOCS_LIMIT_LINES" \
      "${PREVIOUS_REPORT:-}"
  fi
fi

if [[ -f "$REPORT_PATH_MD" ]]; then
  final_score="$(jq -r '.scores.overall // "n/a"' "$REPORT_DATA_PATH" 2>/dev/null || echo "n/a")"
  echo ""
  echo "Report complete:"
  echo "  Markdown: $REPORT_PATH_MD"
  echo "  Data JSON: $REPORT_DATA_PATH"
  echo "  Overall score: $final_score"
else
  echo ""
  echo "Run complete for selected phase(s)."
fi
