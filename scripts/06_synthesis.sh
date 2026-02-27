#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/06_synthesis.sh <repo_path> <reviews_dir> <report_path_md> <model_synthesis> <docs_limit_lines> [previous_report_path_or_empty]
EOF
}

if [[ $# -lt 5 || $# -gt 6 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
REVIEWS_DIR="$2"
REPORT_PATH_MD="$3"
MODEL_SYNTHESIS="$4"
DOCS_LIMIT_LINES="$5"
PREVIOUS_REPORT="${6:-}"

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

if [[ ! -d "$REVIEWS_DIR" ]]; then
  echo "Error: reviews_dir is not a directory: $REVIEWS_DIR" >&2
  exit 2
fi

if [[ ! -f "$REPO_PATH/CLAUDE.md" ]]; then
  echo "Error: CLAUDE.md not found at: $REPO_PATH/CLAUDE.md" >&2
  exit 2
fi

if [[ ! -f "$REPO_PATH/modules.json" ]]; then
  echo "Error: modules.json not found at: $REPO_PATH/modules.json" >&2
  exit 2
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: required command not found: claude" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: required command not found: jq" >&2
  exit 2
fi

if ! [[ "$DOCS_LIMIT_LINES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: docs_limit_lines must be a positive integer: $DOCS_LIMIT_LINES" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPT_TEMPLATE_PATH="$TOOLKIT_ROOT/prompts/synthesis.md"

if [[ ! -f "$PROMPT_TEMPLATE_PATH" ]]; then
  echo "Error: prompt template not found: $PROMPT_TEMPLATE_PATH" >&2
  exit 2
fi

PROMPT_TEMPLATE_CONTENT="$(cat "$PROMPT_TEMPLATE_PATH")"

strip_outer_code_fence_if_present() {
  local file_path="$1"
  local first_nonempty
  local last_nonempty
  local first_line
  local last_line
  local tmp_file

  first_nonempty="$(awk '/[^[:space:]]/{print NR; exit}' "$file_path")"
  last_nonempty="$(awk '/[^[:space:]]/ {last=NR} END{if (last) print last}' "$file_path")"

  if [[ -z "${first_nonempty:-}" || -z "${last_nonempty:-}" ]]; then
    return
  fi

  first_line="$(sed -n "${first_nonempty}p" "$file_path")"
  last_line="$(sed -n "${last_nonempty}p" "$file_path")"

  if [[ "$first_line" =~ ^\`\`\`[[:alnum:]_.-]*[[:space:]]*$ && "$last_line" =~ ^\`\`\`[[:space:]]*$ ]]; then
    tmp_file="$(mktemp)"
    awk -v start="$first_nonempty" -v end="$last_nonempty" '
      NR > start && NR < end { print }
    ' "$file_path" > "$tmp_file"
    mv "$tmp_file" "$file_path"
  fi
}

validate_synthesis_markdown() {
  local report_path="$1"
  local noisy="${2:-true}"
  local first_nonempty_line
  local section
  local line_no
  local last_line=0

  emit_validation_error() {
    if [[ "$noisy" == "true" ]]; then
      echo "$1" >&2
    fi
  }

  first_nonempty_line="$(awk '/[^[:space:]]/{print; exit}' "$report_path")"
  if [[ -z "${first_nonempty_line:-}" ]]; then
    emit_validation_error "Error: synthesis output is empty after normalization"
    return 1
  fi

  if [[ ! "$first_nonempty_line" =~ ^#\ .+\ —\ Quality\ Report$ ]]; then
    emit_validation_error "Error: synthesis output missing required title format '# {Codebase Name} — Quality Report'"
    return 1
  fi

  for section in \
    "^## Final Score:" \
    "^## Codebase Overview$" \
    "^## Top Recommendations$" \
    "^## Module Reports$" \
    "^## Appendix: Medium & Low Findings$" \
    "^## Appendix: Static Analysis Tool Summary$"
  do
    line_no="$(grep -nE "$section" "$report_path" | head -n 1 | cut -d: -f1 || true)"
    if [[ -z "${line_no:-}" ]]; then
      emit_validation_error "Error: synthesis output missing required section matching: $section"
      return 1
    fi
    if (( line_no <= last_line )); then
      emit_validation_error "Error: synthesis output sections are out of order at pattern: $section"
      return 1
    fi
    last_line="$line_no"
  done

  return 0
}

# -------------------------------------------------------------------
# Collect review JSON files
# -------------------------------------------------------------------

shopt -s nullglob

COMP_FILES=("$REVIEWS_DIR"/comprehensive_*.json)
SEC_FILES=("$REVIEWS_DIR"/security_*.json)

shopt -u nullglob

if [[ ${#COMP_FILES[@]} -eq 0 && ${#SEC_FILES[@]} -eq 0 ]]; then
  echo "Error: no review JSON files found in: $REVIEWS_DIR" >&2
  exit 1
fi

ALL_COMPREHENSIVE=""
compact_review_json_for_synthesis() {
  local review_path="$1"
  if ! jq empty "$review_path" >/dev/null 2>&1; then
    head -c 4000 "$review_path"
    return
  fi

  jq -c '
    if has("error") then
      {
        error,
        module_id: (.module_id // null),
        module_name: (.module_name // null),
        review_type: (.review_type // null),
        raw: ((.raw // "") | tostring | .[0:2000])
      }
    elif .review_type == "comprehensive" then
      {
        module_id,
        module_name,
        review_type,
        model,
        timestamp,
        scores,
        summary,
        positive_observations,
        fix_order,
        findings: [
          .findings[] | {
            id,
            title,
            severity,
            category,
            subcategory,
            confidence,
            file,
            line_start,
            line_end,
            description,
            risk,
            fix,
            is_bug,
            is_tech_debt,
            estimated_fix_effort,
            sast_corroborated,
            sast_source
          }
        ]
      }
    elif .review_type == "security" then
      {
        module_id,
        module_name,
        review_type,
        model,
        timestamp,
        scores,
        summary,
        fix_order,
        findings: [
          .findings[] | {
            id,
            title,
            severity,
            category,
            subcategory,
            cwe,
            owasp,
            confidence,
            file,
            line_start,
            line_end,
            description,
            risk,
            fix,
            sast_corroborated,
            sast_source,
            verified_by_sast
          }
        ],
        secrets_found,
        dependency_vulnerabilities
      }
    else .
    end
  ' "$review_path"
}

ALL_COMPREHENSIVE=""
for f in "${COMP_FILES[@]}"; do
  ALL_COMPREHENSIVE+="--- $(basename "$f") ---"$'\n'
  ALL_COMPREHENSIVE+="$(compact_review_json_for_synthesis "$f")"$'\n\n'
done
[[ -z "$ALL_COMPREHENSIVE" ]] && ALL_COMPREHENSIVE="(not available)"

ALL_SECURITY=""
for f in "${SEC_FILES[@]}"; do
  ALL_SECURITY+="--- $(basename "$f") ---"$'\n'
  ALL_SECURITY+="$(compact_review_json_for_synthesis "$f")"$'\n\n'
done
[[ -z "$ALL_SECURITY" ]] && ALL_SECURITY="(not available)"

# -------------------------------------------------------------------
# Collect documentation files (priority-based)
# -------------------------------------------------------------------

DOCS_CONTENT=""

PRIORITY_1=(README.md README.rst ARCHITECTURE.md DESIGN.md SECURITY.md)
for doc in "${PRIORITY_1[@]}"; do
  doc_path="$REPO_PATH/$doc"
  if [[ -f "$doc_path" ]]; then
    DOCS_CONTENT+="--- $doc (priority 1, capped at 500 lines) ---"$'\n'
    DOCS_CONTENT+="$(head -n 500 "$doc_path")"$'\n\n'
  fi
done

PRIORITY_2=(
  docs/architecture.md
  docs/api.md
  docs/overview.md
  openapi.yaml
  swagger.yaml
  swagger.json
  .env.example
)
for doc in "${PRIORITY_2[@]}"; do
  doc_path="$REPO_PATH/$doc"
  if [[ -f "$doc_path" ]]; then
    DOCS_CONTENT+="--- $doc (priority 2, capped at $DOCS_LIMIT_LINES lines) ---"$'\n'
    DOCS_CONTENT+="$(head -n "$DOCS_LIMIT_LINES" "$doc_path")"$'\n\n'
  fi
done

[[ -z "$DOCS_CONTENT" ]] && DOCS_CONTENT="(not available)"

# -------------------------------------------------------------------
# Handle optional previous report
# -------------------------------------------------------------------

if [[ -n "$PREVIOUS_REPORT" && -f "$PREVIOUS_REPORT" ]]; then
  PREVIOUS_REPORT_SUMMARY="$(jq '{
    date: .generated_at,
    final_score: .scores.overall,
    module_scores: [.modules[] | {name, score: .scores.overall}]
  }' "$PREVIOUS_REPORT" 2>/dev/null || echo '{"error": "failed to parse previous report"}')"
else
  PREVIOUS_REPORT_SUMMARY="No previous report provided."
fi

# -------------------------------------------------------------------
# Load remaining token content
# -------------------------------------------------------------------

ROOT_CLAUDE_MD_CONTENT="$(cat "$REPO_PATH/CLAUDE.md")"
MODULES_JSON_CONTENT="$(cat "$REPO_PATH/modules.json")"

# -------------------------------------------------------------------
# Token substitution (Contract 2)
# -------------------------------------------------------------------

ASSEMBLED_PROMPT="${PROMPT_TEMPLATE_CONTENT//\[ROOT_CLAUDE_MD_CONTENT\]/$ROOT_CLAUDE_MD_CONTENT}"
ASSEMBLED_PROMPT="${ASSEMBLED_PROMPT//\[MODULES_JSON_CONTENT\]/$MODULES_JSON_CONTENT}"
ASSEMBLED_PROMPT="${ASSEMBLED_PROMPT//\[DOCS_CONTENT\]/$DOCS_CONTENT}"
ASSEMBLED_PROMPT="${ASSEMBLED_PROMPT//\[PREVIOUS_REPORT_SUMMARY\]/$PREVIOUS_REPORT_SUMMARY}"
ASSEMBLED_PROMPT="${ASSEMBLED_PROMPT//\[ALL_COMPREHENSIVE_REVIEW_JSON\]/$ALL_COMPREHENSIVE}"
ASSEMBLED_PROMPT="${ASSEMBLED_PROMPT//\[ALL_SECURITY_REVIEW_JSON\]/$ALL_SECURITY}"

# -------------------------------------------------------------------
# Invoke Claude
# -------------------------------------------------------------------

REPORT_DIR="$(dirname "$REPORT_PATH_MD")"
mkdir -p "$REPORT_DIR"

RAW_OUTPUT_PATH="${REPORT_PATH_MD%.md}_raw.txt"

echo "Running Phase 6 synthesis..."
attempt_prompt="$ASSEMBLED_PROMPT"
for attempt in 1 2; do
  prompt_file="$(mktemp)"
  printf '%s' "$attempt_prompt" > "$prompt_file"
  if ! claude \
    --model "$MODEL_SYNTHESIS" \
    --dangerously-skip-permissions \
    -p \
    < "$prompt_file" \
    > "$RAW_OUTPUT_PATH"; then
    rm -f "$prompt_file"
    echo "Error: Claude synthesis invocation failed (model/context/runtime)." >&2
    exit 1
  fi
  rm -f "$prompt_file"

  if [[ ! -s "$RAW_OUTPUT_PATH" ]]; then
    echo "Error: Claude returned empty output for synthesis" >&2
    exit 1
  fi

  strip_outer_code_fence_if_present "$RAW_OUTPUT_PATH"
  if validate_synthesis_markdown "$RAW_OUTPUT_PATH" "false"; then
    break
  fi

  if [[ "$attempt" -eq 2 ]]; then
    validate_synthesis_markdown "$RAW_OUTPUT_PATH" "true" || true
    echo "Error: synthesis output failed required markdown structure validation after retry." >&2
    exit 1
  fi

  attempt_prompt="${ASSEMBLED_PROMPT}"$'\n\n'"IMPORTANT: Output ONLY markdown (no code fences) and follow the required section titles/order exactly."
done

# -------------------------------------------------------------------
# Validate and write report
# -------------------------------------------------------------------

cp "$RAW_OUTPUT_PATH" "$REPORT_PATH_MD"

# -------------------------------------------------------------------
# Generate report_data.json (Contract 4: minimum required fields)
# Computed deterministically from review JSONs, not from Claude output.
# Handles error-JSON fallback gracefully (modules with errors score 0).
# -------------------------------------------------------------------

REPORT_DATA_PATH="${REPORT_PATH_MD%.md}_data.json"

if [[ ${#COMP_FILES[@]} -gt 0 ]]; then
  jq -n \
    --argjson reviews "$(jq -s '.' "${COMP_FILES[@]}")" \
    --argjson modules "$(cat "$REPO_PATH/modules.json")" \
    '
    ($reviews | map(
      if has("error") then
        { module_id: .module_id, module_name: (.module_name // "unknown"), overall: 0 }
      else
        { module_id: .module_id, module_name: .module_name, overall: .scores.overall }
      end
    )) as $scored |

    ($scored | map(
      . as $s |
      ((($modules.modules[] | select(.id == $s.module_id) | .estimated_file_count) // 1)) as $w
      | if ($w | type == "number" and $w > 0) then $w else 1 end
    )) as $weights |
    ($weights | add) as $total_weight |

    {
      generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      scores: {
        overall: (
          if ($scored | length) > 0 then
            if ($total_weight > 0) then
              ([range($scored | length)] | map($scored[.].overall * $weights[.]) | add)
              / $total_weight
              | round
            else
              (([$scored[].overall] | add) / ($scored | length) | round)
            end
          else 0 end
        )
      },
      modules: [
        $scored[] | { name: .module_name, scores: { overall: .overall } }
      ]
    }
    ' > "$REPORT_DATA_PATH"
else
  jq -n '{
    generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    scores: { overall: 0 },
    modules: []
  }' > "$REPORT_DATA_PATH"
fi

echo "Phase 6 complete:"
echo "  Raw output: $RAW_OUTPUT_PATH"
echo "  Report: $REPORT_PATH_MD"
echo "  Report data: $REPORT_DATA_PATH"
