#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/05_ai_review.sh <repo_path> <static_dir> <reviews_dir> <model_default> <model_security> <parallel_limit>
EOF
}

if [[ $# -ne 6 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
STATIC_DIR="$2"
REVIEWS_DIR="$3"
MODEL_DEFAULT="$4"
MODEL_SECURITY="$5"
PARALLEL_LIMIT="$6"

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

if [[ ! -d "$STATIC_DIR" ]]; then
  echo "Error: static_dir is not a directory: $STATIC_DIR" >&2
  exit 2
fi

if [[ -z "$MODEL_DEFAULT" || -z "$MODEL_SECURITY" ]]; then
  echo "Error: model_default and model_security are required" >&2
  exit 2
fi

if ! [[ "$PARALLEL_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: parallel_limit must be a positive integer: $PARALLEL_LIMIT" >&2
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

if ! command -v realpath >/dev/null 2>&1; then
  echo "Error: required command not found: realpath" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ROOT_CLAUDE_PATH="$REPO_PATH/CLAUDE.md"
MODULES_JSON_PATH="$REPO_PATH/modules.json"
PROMPT_COMPREHENSIVE_PATH="$TOOLKIT_ROOT/prompts/comprehensive_review.md"
PROMPT_SECURITY_PATH="$TOOLKIT_ROOT/prompts/security_review.md"

for required_file in \
  "$PROMPT_COMPREHENSIVE_PATH" \
  "$PROMPT_SECURITY_PATH" \
  "$MODULES_JSON_PATH"
do
  if [[ ! -f "$required_file" ]]; then
    echo "Error: required file not found: $required_file" >&2
    exit 2
  fi
done

mkdir -p "$REVIEWS_DIR"

if ! jq empty "$MODULES_JSON_PATH" >/dev/null 2>&1; then
  echo "Error: modules.json is not valid JSON" >&2
  exit 1
fi

if ! jq -e '
  type == "object" and
  has("modules") and
  has("review_order") and
  (.modules | type == "array") and
  (.review_order | type == "array") and
  (.modules | length > 0) and
  all(.modules[];
    (.id | type == "number") and
    (.name | type == "string" and length > 0) and
    (.path | type == "string" and length > 0) and
    (.claude_md_path | type == "string" and length > 0)
  ) and
  (([.modules[].id] | unique | length) == (.modules | length)) and
  ((.modules | map(.id)) as $ids | all(.review_order[]; ($ids | index(.) != null)))
' "$MODULES_JSON_PATH" >/dev/null; then
  echo "Error: modules.json failed required schema validation for Phase 5" >&2
  exit 1
fi

MAX_SOURCE_TOKENS_PER_REVIEW="${MAX_SOURCE_TOKENS_PER_REVIEW:-80000}"
if ! [[ "$MAX_SOURCE_TOKENS_PER_REVIEW" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: MAX_SOURCE_TOKENS_PER_REVIEW must be a positive integer: $MAX_SOURCE_TOKENS_PER_REVIEW" >&2
  exit 2
fi
MAX_SOURCE_CHARS=$((MAX_SOURCE_TOKENS_PER_REVIEW * 4))

ROOT_CLAUDE_MD_CONTENT="(not available)"
if [[ -f "$ROOT_CLAUDE_PATH" ]]; then
  ROOT_CLAUDE_MD_CONTENT="$(cat "$ROOT_CLAUDE_PATH")"
  if [[ -z "${ROOT_CLAUDE_MD_CONTENT:-}" ]]; then
    ROOT_CLAUDE_MD_CONTENT="(not available)"
  fi
fi

PROMPT_COMPREHENSIVE_TEMPLATE="$(cat "$PROMPT_COMPREHENSIVE_PATH")"
PROMPT_SECURITY_TEMPLATE="$(cat "$PROMPT_SECURITY_PATH")"

for required_token in \
  "[ROOT_CLAUDE_MD_CONTENT]" \
  "[MODULE_CLAUDE_MD_CONTENT]" \
  "[SEMGREP_FINDINGS_JSON]" \
  "[LIZARD_FINDINGS_JSON]" \
  "[OSV_FINDINGS_JSON]" \
  "[SOURCE_FILE_CONTENTS]"
do
  if [[ "$PROMPT_COMPREHENSIVE_TEMPLATE" != *"$required_token"* ]]; then
    echo "Error: comprehensive prompt missing required token: $required_token" >&2
    exit 1
  fi
done

for required_token in \
  "[ROOT_CLAUDE_MD_CONTENT]" \
  "[MODULE_CLAUDE_MD_CONTENT]" \
  "[SEMGREP_FINDINGS_JSON]" \
  "[GITLEAKS_FINDINGS_JSON]" \
  "[TRUFFLEHOG_FINDINGS_JSON]" \
  "[OSV_FINDINGS_JSON]" \
  "[SOURCE_FILE_CONTENTS]"
do
  if [[ "$PROMPT_SECURITY_TEMPLATE" != *"$required_token"* ]]; then
    echo "Error: security prompt missing required token: $required_token" >&2
    exit 1
  fi
done

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

extract_json_candidate() {
  local input_file="$1"
  local output_file="$2"
  awk '
    /\{/ && start==0 { start=NR }
    /\}/ { last=NR }
    { lines[NR]=$0 }
    END {
      if (start > 0 && last >= start) {
        for (i = start; i <= last; i++) print lines[i]
      }
    }
  ' "$input_file" > "$output_file"
}

normalize_json_response() {
  local raw_file="$1"
  local normalized_file="$2"
  local tmp_file
  local extracted_file

  tmp_file="$(mktemp)"
  extracted_file="$(mktemp)"
  cp "$raw_file" "$tmp_file"
  strip_outer_code_fence_if_present "$tmp_file"

  if jq empty "$tmp_file" >/dev/null 2>&1; then
    cp "$tmp_file" "$normalized_file"
    rm -f "$tmp_file" "$extracted_file"
    return 0
  fi

  extract_json_candidate "$tmp_file" "$extracted_file"
  if [[ -s "$extracted_file" ]] && jq empty "$extracted_file" >/dev/null 2>&1; then
    cp "$extracted_file" "$normalized_file"
    rm -f "$tmp_file" "$extracted_file"
    return 0
  fi

  rm -f "$tmp_file" "$extracted_file"
  return 1
}

sanitize_module_name() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  value="$(printf "%s" "$value" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g')"
  if [[ -z "${value:-}" ]]; then
    value="module"
  fi
  printf "%s" "$value"
}

resolve_path_within_repo() {
  local candidate_rel="$1"
  local candidate_label="$2"
  local resolved

  if [[ "$candidate_rel" == /* ]]; then
    echo "Error: $candidate_label must be relative, got absolute path: $candidate_rel" >&2
    return 1
  fi

  resolved="$(realpath -m "$REPO_PATH/$candidate_rel")"
  case "$resolved" in
    "$REPO_PATH"|"$REPO_PATH"/*)
      printf "%s" "$resolved"
      return 0
      ;;
    *)
      echo "Error: $candidate_label escapes repo root: $candidate_rel" >&2
      return 1
      ;;
  esac
}

filter_static_findings_json() {
  local input_path="$1"
  local module_path="$2"

  if [[ ! -f "$input_path" ]]; then
    printf '{"skipped":true,"reason":"not_available"}\n'
    return
  fi

  if ! jq empty "$input_path" >/dev/null 2>&1; then
    printf '{"error":"invalid_json_input","path":"%s"}\n' "$input_path"
    return
  fi

  if [[ "$module_path" == "." ]]; then
    cat "$input_path"
    return
  fi

  jq --arg mp "$module_path" --arg repo "$REPO_PATH" '
    def normpath:
      tostring
      | gsub("\\\\"; "/")
      | gsub("/+"; "/")
      | sub("^\\./"; "");
    def path_of:
      (.path // .file // .filename // .File // .location.path // .SourceMetadata.Data.Filesystem.file // "");
    def in_module($p):
      ($mp | normpath) as $mpn
      | ($p | normpath) as $n
      | ($repo | normpath) as $r
      | ($n == $mpn)
        or ($n | startswith($mpn + "/"))
        or ($n == ($r + "/" + $mpn))
        or ($n | startswith($r + "/" + $mpn + "/"));
    if (type == "object" and (has("skipped") or has("error"))) then .
    elif type == "array" then
      map(select((path_of | tostring) as $p | ($p != "" and in_module($p))))
    elif (type == "object" and has("results") and (.results | type == "array")) then
      .results |= map(select((path_of | tostring) as $p | ($p != "" and in_module($p))))
    elif (type == "object" and has("findings") and (.findings | type == "array")) then
      .findings |= map(select((path_of | tostring) as $p | ($p != "" and in_module($p))))
    elif (type == "object" and has("issues") and (.issues | type == "array")) then
      .issues |= map(select((path_of | tostring) as $p | ($p != "" and in_module($p))))
    elif (type == "object" and has("runs") and (.runs | type == "array")) then
      .runs |= map(
        if (has("results") and (.results | type == "array")) then
          .results |= map(select((path_of | tostring) as $p | ($p != "" and in_module($p))))
        else .
        end
      )
    else .
    end
  ' "$input_path"
}

read_module_source_contents() {
  local module_path="$1"
  local files=()
  local prioritized=()
  local file
  local abs_file
  local priority
  local lower
  local source_blob=""
  local omitted=0

  mapfile -t files < <(
    cd "$REPO_PATH"
    find "$module_path" -type f | sort || true
  )

  if [[ "${#files[@]}" -eq 0 ]]; then
    printf "(not available)"
    return
  fi

  mapfile -t prioritized < <(
    for file in "${files[@]}"; do
      lower="$(printf "%s" "$file" | tr '[:upper:]' '[:lower:]')"
      priority=5
      if [[ "$lower" =~ auth|security|jwt|token|oauth ]]; then
        priority=1
      elif [[ "$lower" =~ route|controller|handler|resolver|api ]]; then
        priority=2
      elif [[ "$lower" =~ service|usecase|worker|job|queue ]]; then
        priority=3
      elif [[ "$lower" =~ util|helper|common|lib ]]; then
        priority=4
      fi
      printf "%d\t%s\n" "$priority" "$file"
    done | sort -t $'\t' -k1,1n -k2,2 | cut -f2-
  )

  for file in "${prioritized[@]}"; do
    abs_file="$REPO_PATH/$file"
    if [[ ! -f "$abs_file" ]]; then
      continue
    fi

    if ! grep -Iq . "$abs_file" 2>/dev/null; then
      continue
    fi

    local block
    block="===== FILE: $file ====="$'\n'"$(cat "$abs_file")"$'\n\n'

    if (( ${#source_blob} + ${#block} > MAX_SOURCE_CHARS )); then
      omitted=$((omitted + 1))
      continue
    fi
    source_blob+="$block"
  done

  if (( omitted > 0 )); then
    source_blob+=$'\n'"[OMITTED_FILES_DUE_TOKEN_BUDGET]=$omitted"$'\n'
  fi

  if [[ -z "${source_blob:-}" ]]; then
    source_blob="(not available)"
  fi

  printf "%s" "$source_blob"
}

validate_comprehensive_json() {
  local input_path="$1"
  jq -e '
    def sev: . == "CRITICAL" or . == "HIGH" or . == "MEDIUM" or . == "LOW";
    def conf: . == "HIGH" or . == "MEDIUM" or . == "LOW";
    def grade: . == "A" or . == "B" or . == "C" or . == "D" or . == "F";
    def score_0_100: (type == "number" and . >= 0 and . <= 100);
    def num_or_null: (type == "number" or type == "null");
    def str_or_null: (type == "string" or type == "null");
    type == "object" and
    (.module_id | type == "number") and
    (.module_name | type == "string") and
    (.review_type == "comprehensive") and
    (.model | type == "string") and
    (.timestamp | type == "string") and
    (.scores | type == "object") and
    (.scores.overall | score_0_100) and
    (.scores.bug_score | score_0_100) and
    (.scores.tech_debt_score | score_0_100) and
    (.scores.documentation_score | score_0_100) and
    (.scores.grade | grade) and
    (.findings | type == "array") and
    all(.findings[];
      (.id | type == "string") and
      (.title | type == "string") and
      (.severity | sev) and
      (.category | type == "string") and
      (.subcategory | type == "string") and
      (.confidence | conf) and
      (.file | type == "string") and
      (.line_start | num_or_null) and
      (.line_end | num_or_null) and
      (.description | type == "string") and
      (.risk | type == "string") and
      (.fix | type == "string") and
      (.code_snippet | str_or_null) and
      (.fix_snippet | str_or_null) and
      (.is_bug | type == "boolean") and
      (.is_tech_debt | type == "boolean") and
      (.estimated_fix_effort == "LOW" or .estimated_fix_effort == "MEDIUM" or .estimated_fix_effort == "HIGH") and
      (.sast_corroborated | type == "boolean") and
      (.sast_source | str_or_null)
    ) and
    (.positive_observations | type == "array") and
    all(.positive_observations[]; type == "string") and
    (.summary | type == "string") and
    (.fix_order | type == "array") and
    all(.fix_order[]; (.id | type == "string") and (.reason | type == "string"))
  ' "$input_path" >/dev/null
}

validate_security_json() {
  local input_path="$1"
  jq -e '
    def sev: . == "CRITICAL" or . == "HIGH" or . == "MEDIUM" or . == "LOW";
    def secret_sev: . == "CRITICAL" or . == "HIGH";
    def conf: . == "HIGH" or . == "MEDIUM" or . == "LOW";
    def grade: . == "A" or . == "B" or . == "C" or . == "D" or . == "F";
    def score_0_100: (type == "number" and . >= 0 and . <= 100);
    def num_or_null: (type == "number" or type == "null");
    def str_or_null: (type == "string" or type == "null");
    type == "object" and
    (.module_id | type == "number") and
    (.module_name | type == "string") and
    (.review_type == "security") and
    (.model | type == "string") and
    (.timestamp | type == "string") and
    (.scores | type == "object") and
    (.scores.security_score | score_0_100) and
    (.scores.grade | grade) and
    (.findings | type == "array") and
    all(.findings[];
      (.id | type == "string") and
      (.title | type == "string") and
      (.severity | sev) and
      (.category | type == "string") and
      (.subcategory | type == "string") and
      (.cwe | str_or_null) and
      (.owasp | str_or_null) and
      (.confidence | conf) and
      (.file | type == "string") and
      (.line_start | num_or_null) and
      (.line_end | num_or_null) and
      (.description | type == "string") and
      (.risk | type == "string") and
      (.fix | type == "string") and
      (.code_snippet | str_or_null) and
      (.fix_snippet | str_or_null) and
      (.sast_corroborated | type == "boolean") and
      (.sast_source | str_or_null) and
      (.verified_by_sast | type == "boolean")
    ) and
    (.secrets_found | type == "array") and
    all(.secrets_found[];
      (.type | type == "string") and
      (.file | type == "string") and
      (.line | num_or_null) and
      (.description | type == "string") and
      (.severity | secret_sev) and
      (.source | type == "string")
    ) and
    (.dependency_vulnerabilities | type == "array") and
    all(.dependency_vulnerabilities[];
      (.package | type == "string") and
      (.version | type == "string") and
      (.vulnerability_id | type == "string") and
      (.severity | sev) and
      (.fix_version | str_or_null) and
      (.description | type == "string") and
      (.source | type == "string")
    ) and
    (.summary | type == "string") and
    (.fix_order | type == "array") and
    all(.fix_order[]; (.id | type == "string") and (.reason | type == "string"))
  ' "$input_path" >/dev/null
}

write_invalid_json_fallback() {
  local output_path="$1"
  local module_id="$2"
  local raw_file="$3"
  local raw_content
  local max_raw=20000

  raw_content="$(cat "$raw_file")"
  if (( ${#raw_content} > max_raw )); then
    raw_content="${raw_content:0:max_raw}...[truncated]"
  fi

  jq -n --argjson module_id "$module_id" --arg raw "$raw_content" \
    '{error:"agent_output_invalid_json", module_id:$module_id, raw:$raw}' > "$output_path"
}

run_review_worker() {
  local module_id="$1"
  local review_kind="$2"
  local module_json
  local module_name
  local module_path_raw
  local module_path
  local module_abs
  local module_claude_rel
  local module_claude_abs
  local module_claude_content
  local safe_module_name
  local output_path
  local prompt_template
  local model_name
  local semgrep_json
  local lizard_json
  local gitleaks_json
  local trufflehog_json
  local osv_json
  local source_file_contents
  local assembled_prompt
  local attempt
  local raw_file
  local normalized_file
  local retry_note=""

  module_json="$(jq -c --argjson id "$module_id" '.modules[] | select(.id == $id)' "$MODULES_JSON_PATH")"
  if [[ -z "${module_json:-}" ]]; then
    echo "Error: module id not found in modules.json: $module_id" >&2
    return 1
  fi

  module_name="$(jq -r '.name' <<< "$module_json")"
  module_path_raw="$(jq -r '.path' <<< "$module_json")"
  module_claude_rel="$(jq -r '.claude_md_path' <<< "$module_json")"
  if ! module_abs="$(resolve_path_within_repo "$module_path_raw" "module path")"; then
    return 1
  fi
  module_path="$(realpath --relative-to="$REPO_PATH" "$module_abs")"
  module_path="${module_path:-.}"
  if [[ ! -d "$module_abs" ]]; then
    echo "Error: module path does not exist for id $module_id: $module_path_raw" >&2
    return 1
  fi

  if ! module_claude_abs="$(resolve_path_within_repo "$module_claude_rel" "claude_md_path")"; then
    return 1
  fi

  module_claude_content="(not available)"
  if [[ -f "$module_claude_abs" ]]; then
    module_claude_content="$(cat "$module_claude_abs")"
    if [[ -z "${module_claude_content:-}" ]]; then
      module_claude_content="(not available)"
    fi
  fi

  semgrep_json="$(filter_static_findings_json "$STATIC_DIR/semgrep.json" "$module_path")"
  lizard_json="$(filter_static_findings_json "$STATIC_DIR/lizard.json" "$module_path")"
  gitleaks_json="$(filter_static_findings_json "$STATIC_DIR/gitleaks.json" "$module_path")"
  trufflehog_json="$(filter_static_findings_json "$STATIC_DIR/trufflehog.json" "$module_path")"

  if [[ -f "$STATIC_DIR/osv.json" ]] && jq empty "$STATIC_DIR/osv.json" >/dev/null 2>&1; then
    osv_json="$(cat "$STATIC_DIR/osv.json")"
  else
    osv_json='{"skipped":true,"reason":"not_available"}'
  fi

  source_file_contents="$(read_module_source_contents "$module_path")"

  safe_module_name="$(sanitize_module_name "$module_name")"
  if [[ "$review_kind" == "comprehensive" ]]; then
    prompt_template="$PROMPT_COMPREHENSIVE_TEMPLATE"
    model_name="$MODEL_DEFAULT"
    output_path="$REVIEWS_DIR/comprehensive_${module_id}_${safe_module_name}.json"
  else
    prompt_template="$PROMPT_SECURITY_TEMPLATE"
    model_name="$MODEL_SECURITY"
    output_path="$REVIEWS_DIR/security_${module_id}_${safe_module_name}.json"
  fi

  for attempt in 1 2; do
    assembled_prompt="$prompt_template"
    assembled_prompt="${assembled_prompt//\[ROOT_CLAUDE_MD_CONTENT\]/$ROOT_CLAUDE_MD_CONTENT}"
    assembled_prompt="${assembled_prompt//\[MODULE_CLAUDE_MD_CONTENT\]/$module_claude_content}"
    assembled_prompt="${assembled_prompt//\[SEMGREP_FINDINGS_JSON\]/$semgrep_json}"
    assembled_prompt="${assembled_prompt//\[OSV_FINDINGS_JSON\]/$osv_json}"
    assembled_prompt="${assembled_prompt//\[SOURCE_FILE_CONTENTS\]/$source_file_contents}"

    if [[ "$review_kind" == "comprehensive" ]]; then
      assembled_prompt="${assembled_prompt//\[LIZARD_FINDINGS_JSON\]/$lizard_json}"
    else
      assembled_prompt="${assembled_prompt//\[GITLEAKS_FINDINGS_JSON\]/$gitleaks_json}"
      assembled_prompt="${assembled_prompt//\[TRUFFLEHOG_FINDINGS_JSON\]/$trufflehog_json}"
    fi

    if [[ -n "$retry_note" ]]; then
      assembled_prompt+=$'\n\n'"$retry_note"
    fi

    raw_file="$(mktemp)"
    normalized_file="$(mktemp)"
    if ! printf '%s' "$assembled_prompt" | claude --model "$model_name" --dangerously-skip-permissions -p > "$raw_file"; then
      rm -f "$normalized_file"
      if [[ "$attempt" -eq 2 ]]; then
        write_invalid_json_fallback "$output_path" "$module_id" "$raw_file"
        rm -f "$raw_file"
        return 0
      fi
      rm -f "$raw_file"
      retry_note="IMPORTANT: respond with ONLY valid JSON and no markdown fences."
      continue
    fi

    if normalize_json_response "$raw_file" "$normalized_file"; then
      if [[ "$review_kind" == "comprehensive" ]]; then
        if validate_comprehensive_json "$normalized_file"; then
          cp "$normalized_file" "$output_path"
          rm -f "$raw_file" "$normalized_file"
          echo "Phase 5 complete: module=$module_id type=comprehensive"
          return 0
        fi
      else
        if validate_security_json "$normalized_file"; then
          cp "$normalized_file" "$output_path"
          rm -f "$raw_file" "$normalized_file"
          echo "Phase 5 complete: module=$module_id type=security"
          return 0
        fi
      fi
    fi

    if [[ "$attempt" -eq 2 ]]; then
      write_invalid_json_fallback "$output_path" "$module_id" "$raw_file"
      rm -f "$raw_file" "$normalized_file"
      return 0
    fi

    rm -f "$raw_file" "$normalized_file"
    retry_note="IMPORTANT: respond with ONLY valid JSON and no markdown fences."
  done

  return 1
}

ensure_expected_review_outputs() {
  local module_id
  local module_name
  local safe_name
  local comp_path
  local sec_path
  local missing=0

  for module_id in "${REVIEW_ORDER[@]}"; do
    module_name="$(jq -r --argjson id "$module_id" '.modules[] | select(.id == $id) | .name' "$MODULES_JSON_PATH")"
    safe_name="$(sanitize_module_name "$module_name")"
    comp_path="$REVIEWS_DIR/comprehensive_${module_id}_${safe_name}.json"
    sec_path="$REVIEWS_DIR/security_${module_id}_${safe_name}.json"

    for output in "$comp_path" "$sec_path"; do
      if [[ ! -f "$output" ]]; then
        echo "Error: missing required review output: $output" >&2
        missing=1
        continue
      fi
      if ! jq empty "$output" >/dev/null 2>&1; then
        echo "Error: review output is not valid JSON: $output" >&2
        missing=1
      fi
    done
  done

  return "$missing"
}

mapfile -t REVIEW_ORDER < <(jq -r '.review_order[]' "$MODULES_JSON_PATH")
if [[ "${#REVIEW_ORDER[@]}" -eq 0 ]]; then
  echo "Error: review_order is empty in modules.json" >&2
  exit 1
fi

echo "Running Phase 5 AI reviews..."

declare -a PIDS=()
for module_id in "${REVIEW_ORDER[@]}"; do
  run_review_worker "$module_id" "comprehensive" &
  PIDS+=("$!")
  while [[ "$(jobs -pr | wc -l | awk '{print $1}')" -ge "$PARALLEL_LIMIT" ]]; do
    sleep 1
  done

  run_review_worker "$module_id" "security" &
  PIDS+=("$!")
  while [[ "$(jobs -pr | wc -l | awk '{print $1}')" -ge "$PARALLEL_LIMIT" ]]; do
    sleep 1
  done
done

phase_failed=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    phase_failed=1
  fi
done

if ! ensure_expected_review_outputs; then
  exit 1
fi

if (( phase_failed != 0 )); then
  echo "Error: one or more AI review workers failed unexpectedly." >&2
  exit 1
fi

echo "Phase 5 complete: review outputs written to $REVIEWS_DIR"
