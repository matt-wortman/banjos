#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/03_module_claude_mds.sh <repo_path> <model_default> <parallel_limit>
EOF
}

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
MODEL_DEFAULT="$2"
PARALLEL_LIMIT="$3"

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

if [[ -z "$MODEL_DEFAULT" ]]; then
  echo "Error: model_default is required" >&2
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
PROMPT_TEMPLATE_PATH="$TOOLKIT_ROOT/prompts/module_claude_md.md"
ROOT_CLAUDE_PATH="$REPO_PATH/CLAUDE.md"
MODULES_JSON_PATH="$REPO_PATH/modules.json"
PROGRESS_PATH="$REPO_PATH/.claude_review_progress"

if [[ ! -f "$PROMPT_TEMPLATE_PATH" ]]; then
  echo "Error: prompt template not found: $PROMPT_TEMPLATE_PATH" >&2
  exit 2
fi

if [[ ! -f "$ROOT_CLAUDE_PATH" ]]; then
  echo "Error: root CLAUDE.md not found: $ROOT_CLAUDE_PATH" >&2
  exit 2
fi

if [[ ! -f "$MODULES_JSON_PATH" ]]; then
  echo "Error: modules.json not found: $MODULES_JSON_PATH" >&2
  exit 2
fi

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
  (.review_order | length > 0) and
  all(.modules[];
    (.id | type == "number") and
    (.name | type == "string" and length > 0) and
    (.path | type == "string" and length > 0) and
    (.claude_md_path | type == "string" and length > 0) and
    (.description | type == "string") and
    (.key_concerns | type == "array") and
    (.depends_on | type == "array") and
    (.depended_on_by | type == "array")
  ) and
  (([.modules[].id] | unique | length) == (.modules | length)) and
  ((.modules | map(.id)) as $ids | all(.review_order[]; ($ids | index(.) != null)))
' "$MODULES_JSON_PATH" >/dev/null; then
  echo "Error: modules.json failed required schema validation for Phase 3" >&2
  exit 1
fi

PROMPT_TEMPLATE_CONTENT="$(cat "$PROMPT_TEMPLATE_PATH")"
for required_token in \
  "[ROOT_CLAUDE_MD_CONTENT]" \
  "[MODULE_NAME]" \
  "[MODULE_PATH]" \
  "[MODULE_DESCRIPTION]" \
  "[KEY_CONCERNS]" \
  "[DEPENDS_ON]" \
  "[DEPENDED_ON_BY]" \
  "[FILE_LISTING]"
do
  if [[ "$PROMPT_TEMPLATE_CONTENT" != *"$required_token"* ]]; then
    echo "Error: prompt template missing required token: $required_token" >&2
    exit 1
  fi
done

ROOT_CLAUDE_MD_CONTENT="$(cat "$ROOT_CLAUDE_PATH")"
if [[ -z "${ROOT_CLAUDE_MD_CONTENT:-}" ]]; then
  ROOT_CLAUDE_MD_CONTENT="(not available)"
fi

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

write_progress_status() {
  local module_id="$1"
  local status="$2"
  local module_name="$3"

  if command -v flock >/dev/null 2>&1; then
    {
      flock 9
      printf "module_%s=%s # %s\n" "$module_id" "$status" "$module_name" >> "$PROGRESS_PATH"
    } 9>>"$PROGRESS_PATH"
  else
    printf "module_%s=%s # %s\n" "$module_id" "$status" "$module_name" >> "$PROGRESS_PATH"
  fi
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

normalize_required_heading() {
  local file_path="$1"
  local module_name="$2"
  local first_nonempty_line
  local tmp_file

  first_nonempty_line="$(awk '/[^[:space:]]/{print; exit}' "$file_path")"
  if [[ -z "${first_nonempty_line:-}" ]]; then
    return 1
  fi

  if [[ "$first_nonempty_line" == "# CLAUDE.md —"* ]]; then
    return 0
  fi

  if [[ ! "$first_nonempty_line" =~ ^#\ CLAUDE\.md([[:space:]]|$|[[:space:]]*[-–—]) ]]; then
    return 1
  fi

  tmp_file="$(mktemp)"
  awk -v name="$module_name" '
    BEGIN { replaced=0; seen_nonempty=0 }
    {
      if (!seen_nonempty && $0 ~ /[^[:space:]]/) {
        seen_nonempty=1
      }
      if (seen_nonempty && !replaced && $0 ~ /^# CLAUDE\.md([[:space:]]|$|[[:space:]]*[-–—])/) {
        print "# CLAUDE.md — " name
        replaced=1
      } else {
        print
      }
    }
  ' "$file_path" > "$tmp_file"
  mv "$tmp_file" "$file_path"
  return 0
}

run_module_agent() {
  local module_id="$1"
  local module_json
  local module_name="module_${module_id}"
  local module_path
  local module_abs_path
  local module_path_raw
  local module_path_norm
  local module_output_rel_raw
  local module_output_rel
  local module_output_abs
  local module_description
  local key_concerns
  local depends_on
  local depended_on_by
  local file_listing
  local base_prompt
  local assembled_prompt
  local prompt_file
  local tmp_output
  local line_count
  local retry_note=""
  local attempt

  module_json="$(jq -c --argjson id "$module_id" '.modules[] | select(.id == $id)' "$MODULES_JSON_PATH")"
  if [[ -z "${module_json:-}" ]]; then
    echo "Error: module id $module_id not found in modules.json" >&2
    write_progress_status "$module_id" "FAILED" "$module_name"
    return 1
  fi

  module_name="$(jq -r '.name' <<< "$module_json")"
  module_path_raw="$(jq -r '.path' <<< "$module_json")"
  module_output_rel_raw="$(jq -r '.claude_md_path' <<< "$module_json")"
  module_description="$(jq -r '.description' <<< "$module_json")"
  key_concerns="$(jq -r 'if (.key_concerns | length) > 0 then (.key_concerns | join(", ")) else "none" end' <<< "$module_json")"
  depends_on="$(jq -r 'if (.depends_on | length) > 0 then (.depends_on | join(", ")) else "none" end' <<< "$module_json")"
  depended_on_by="$(jq -r 'if (.depended_on_by | length) > 0 then (.depended_on_by | join(", ")) else "none" end' <<< "$module_json")"

  if [[ -z "${module_description:-}" ]]; then
    module_description="(not available)"
  fi

  if ! module_abs_path="$(resolve_path_within_repo "$module_path_raw" "module path")"; then
    write_progress_status "$module_id" "FAILED" "$module_name"
    return 1
  fi
  module_path_norm="$(realpath --relative-to="$REPO_PATH" "$module_abs_path")"
  module_path="${module_path_norm:-.}"

  if [[ ! -d "$module_abs_path" ]]; then
    echo "Error: module path does not exist for id $module_id: $module_path" >&2
    write_progress_status "$module_id" "FAILED" "$module_name"
    return 1
  fi

  if ! module_output_abs="$(resolve_path_within_repo "$module_output_rel_raw" "claude_md_path")"; then
    write_progress_status "$module_id" "FAILED" "$module_name"
    return 1
  fi
  module_output_rel="$(realpath --relative-to="$REPO_PATH" "$module_output_abs")"
  if [[ "$module_output_abs" == "$REPO_PATH/CLAUDE.md" ]]; then
    echo "Info: module $module_id ($module_name) skipped — root CLAUDE.md already written by Phase 2" >&2
    write_progress_status "$module_id" "SKIPPED" "$module_name"
    return 0
  fi

  file_listing="$(
    cd "$REPO_PATH"
    find "$module_path" -type f | sort || true
  )"
  if [[ -z "${file_listing:-}" ]]; then
    file_listing="(not available)"
  fi

  base_prompt="$PROMPT_TEMPLATE_CONTENT"
  base_prompt="${base_prompt//\[ROOT_CLAUDE_MD_CONTENT\]/$ROOT_CLAUDE_MD_CONTENT}"
  base_prompt="${base_prompt//\[MODULE_NAME\]/$module_name}"
  base_prompt="${base_prompt//\[MODULE_PATH\]/$module_path}"
  base_prompt="${base_prompt//\[MODULE_DESCRIPTION\]/$module_description}"
  base_prompt="${base_prompt//\[KEY_CONCERNS\]/$key_concerns}"
  base_prompt="${base_prompt//\[DEPENDS_ON\]/$depends_on}"
  base_prompt="${base_prompt//\[DEPENDED_ON_BY\]/$depended_on_by}"
  base_prompt="${base_prompt//\[FILE_LISTING\]/$file_listing}"

  for attempt in 1 2; do
    assembled_prompt="$base_prompt"
    if [[ -n "$retry_note" ]]; then
      assembled_prompt+=$'\n\n'"$retry_note"
    fi

    prompt_file="$(mktemp)"
    printf '%s' "$assembled_prompt" > "$prompt_file"
    tmp_output="$(mktemp)"
    if ! claude --model "$MODEL_DEFAULT" --dangerously-skip-permissions -p < "$prompt_file" > "$tmp_output"; then
      rm -f "$prompt_file" "$tmp_output"
      if [[ "$attempt" -lt 2 ]]; then
        retry_note="IMPORTANT: Start directly with '# CLAUDE.md — [Module Name]' and avoid markdown fences."
        continue
      fi
      echo "Error: Claude invocation failed for module $module_id ($module_name)" >&2
      write_progress_status "$module_id" "FAILED" "$module_name"
      return 1
    fi
    rm -f "$prompt_file"

    strip_outer_code_fence_if_present "$tmp_output"

    if ! normalize_required_heading "$tmp_output" "$module_name"; then
      rm -f "$tmp_output"
      if [[ "$attempt" -lt 2 ]]; then
        retry_note="IMPORTANT: Start directly with '# CLAUDE.md — [Module Name]' and avoid markdown fences."
        continue
      fi
      echo "Error: module $module_id output missing required heading '# CLAUDE.md —'" >&2
      write_progress_status "$module_id" "FAILED" "$module_name"
      return 1
    fi

    line_count="$(wc -l < "$tmp_output" | awk '{print $1}')"
    if (( line_count < 30 )); then
      rm -f "$tmp_output"
      if [[ "$attempt" -lt 2 ]]; then
        retry_note="IMPORTANT: Output at least 30 lines and use the exact required structure."
        continue
      fi
      echo "Error: module $module_id output too short ($line_count lines; minimum 30)" >&2
      write_progress_status "$module_id" "FAILED" "$module_name"
      return 1
    fi

    mkdir -p "$(dirname "$module_output_abs")"
    cp "$tmp_output" "$module_output_abs"
    rm -f "$tmp_output"

    write_progress_status "$module_id" "DONE" "$module_name"
    echo "Phase 3 module complete: id=$module_id name=$module_name output=$module_output_rel"
    return 0
  done

  write_progress_status "$module_id" "FAILED" "$module_name"
  return 1
}

: > "$PROGRESS_PATH"

mapfile -t REVIEW_ORDER < <(jq -r '.review_order[]' "$MODULES_JSON_PATH")
if [[ "${#REVIEW_ORDER[@]}" -eq 0 ]]; then
  echo "Error: review_order is empty in modules.json" >&2
  exit 1
fi

echo "Running Phase 3 module CLAUDE.md generation..."

declare -a PIDS=()
for module_id in "${REVIEW_ORDER[@]}"; do
  run_module_agent "$module_id" &
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

for module_id in "${REVIEW_ORDER[@]}"; do
  if ! grep -Eq "^module_${module_id}=(DONE|FAILED|SKIPPED)([[:space:]]|$)" "$PROGRESS_PATH"; then
    echo "Error: missing progress status for module id $module_id" >&2
    phase_failed=1
  fi
done

if (( phase_failed != 0 )); then
  echo "Phase 3 failed; see .claude_review_progress for per-module status." >&2
  exit 1
fi

echo "Phase 3 complete: all module CLAUDE.md files generated."
