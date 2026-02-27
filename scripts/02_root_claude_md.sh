#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/02_root_claude_md.sh <repo_path> <snapshot_input_path> <model_default>
EOF
}

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
SNAPSHOT_INPUT_PATH="$2"
MODEL_DEFAULT="$3"

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

if [[ ! -f "$SNAPSHOT_INPUT_PATH" ]]; then
  echo "Error: snapshot input not found: $SNAPSHOT_INPUT_PATH" >&2
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
PROMPT_TEMPLATE_PATH="$TOOLKIT_ROOT/prompts/root_claude_md.md"

if [[ ! -f "$PROMPT_TEMPLATE_PATH" ]]; then
  echo "Error: prompt template not found: $PROMPT_TEMPLATE_PATH" >&2
  exit 2
fi

PROMPT_TEMPLATE_CONTENT="$(cat "$PROMPT_TEMPLATE_PATH")"
if [[ "$PROMPT_TEMPLATE_CONTENT" != *"[SNAPSHOT_CONTENT]"* ]]; then
  echo "Error: prompt template is missing required token [SNAPSHOT_CONTENT]" >&2
  exit 1
fi

SNAPSHOT_CONTENT="$(cat "$SNAPSHOT_INPUT_PATH")"
ASSEMBLED_PROMPT="${PROMPT_TEMPLATE_CONTENT//\[SNAPSHOT_CONTENT\]/$SNAPSHOT_CONTENT}"

RUN_DIR="$(cd "$(dirname "$SNAPSHOT_INPUT_PATH")/.." && pwd)"
RAW_OUTPUT_PATH="$RUN_DIR/phase2_raw.txt"
mkdir -p "$RUN_DIR"

CLAUDE_OUTPUT_PATH="$REPO_PATH/CLAUDE.md"
MODULES_OUTPUT_PATH="$REPO_PATH/modules.json"

echo "Running Phase 2 root generation..."
prompt_file="$(mktemp)"
printf '%s' "$ASSEMBLED_PROMPT" > "$prompt_file"
claude \
  --model "$MODEL_DEFAULT" \
  --dangerously-skip-permissions \
  -p \
  < "$prompt_file" \
  > "$RAW_OUTPUT_PATH"
rm -f "$prompt_file"

extract_delimited_block() {
  local begin_marker="$1"
  local end_marker="$2"
  local input_file="$3"
  local output_file="$4"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { in_block=1; next }
    $0 == end { in_block=0; exit }
    in_block { print }
  ' "$input_file" > "$output_file"
}

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

tmp_claude="$(mktemp)"
tmp_modules="$(mktemp)"
trap 'rm -f "$tmp_claude" "$tmp_modules"' EXIT

extract_delimited_block "===== BEGIN CLAUDE.md =====" "===== END CLAUDE.md =====" "$RAW_OUTPUT_PATH" "$tmp_claude"
extract_delimited_block "===== BEGIN modules.json =====" "===== END modules.json =====" "$RAW_OUTPUT_PATH" "$tmp_modules"
strip_outer_code_fence_if_present "$tmp_claude"
strip_outer_code_fence_if_present "$tmp_modules"

if [[ ! -s "$tmp_claude" ]]; then
  echo "Error: failed to extract CLAUDE.md block from Claude output" >&2
  exit 1
fi

if [[ ! -s "$tmp_modules" ]]; then
  echo "Error: failed to extract modules.json block from Claude output" >&2
  exit 1
fi

if ! grep -Fq "# CLAUDE.md" "$tmp_claude"; then
  echo "Error: extracted CLAUDE.md content missing required heading '# CLAUDE.md'" >&2
  exit 1
fi

if ! jq empty "$tmp_modules" >/dev/null 2>&1; then
  echo "Error: extracted modules.json is not valid JSON" >&2
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
' "$tmp_modules" >/dev/null; then
  echo "Error: modules.json failed required schema validation for downstream phases" >&2
  exit 1
fi

mapfile -t PHASE2_MODULE_PATHS < <(jq -r '.modules[].path' "$tmp_modules")
for module_path in "${PHASE2_MODULE_PATHS[@]}"; do
  if [[ "$module_path" == /* ]]; then
    echo "Error: modules.json path must be relative, got absolute path: $module_path" >&2
    exit 1
  fi
  resolved_module_path="$(realpath -m "$REPO_PATH/$module_path")"
  case "$resolved_module_path" in
    "$REPO_PATH"|"$REPO_PATH"/*) ;;
    *)
      echo "Error: modules.json path escapes repo root: $module_path" >&2
      exit 1
      ;;
  esac
  if [[ ! -d "$resolved_module_path" ]]; then
    echo "Error: modules.json path does not exist as directory: $module_path" >&2
    exit 1
  fi
done

cp "$tmp_claude" "$CLAUDE_OUTPUT_PATH"
cp "$tmp_modules" "$MODULES_OUTPUT_PATH"

echo "Phase 2 complete:"
echo "  Raw output: $RAW_OUTPUT_PATH"
echo "  CLAUDE.md: $CLAUDE_OUTPUT_PATH"
echo "  modules.json: $MODULES_OUTPUT_PATH"
