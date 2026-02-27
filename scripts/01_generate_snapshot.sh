#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/01_generate_snapshot.sh <repo_path> <snapshot_output_path>
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
OUTPUT_PATH="$2"

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

# Excluded from all find-based scans per spec.
FIND_PRUNE=(
  "(" -type d "("
    -name ".git" -o
    -name "node_modules" -o
    -name "dist" -o
    -name "build" -o
    -name "out" -o
    -name ".next" -o
    -name ".nuxt" -o
    -name "coverage" -o
    -name "__pycache__" -o
    -name ".pytest_cache" -o
    -name ".mypy_cache" -o
    -name ".tox" -o
    -name "venv" -o
    -name ".venv" -o
    -name "env" -o
    -name "vendor" -o
    -name "target" -o
    -name ".cargo" -o
    -name ".gradle" -o
    -name ".idea" -o
    -name ".vscode"
  ")" -prune ")"
)

TREE_IGNORE=".git|node_modules|dist|build|out|.next|.nuxt|coverage|__pycache__|.pytest_cache|.mypy_cache|.tox|venv|.venv|env|vendor|target|.cargo|.gradle|.idea|.vscode"

relpath() {
  local abs="$1"
  if [[ "$abs" == "$REPO_PATH" ]]; then
    printf "."
  else
    printf "%s" "${abs#"$REPO_PATH"/}"
  fi
}

repo_find_files() {
  find "$REPO_PATH" "${FIND_PRUNE[@]}" -o -type f -print
}

repo_find_depth4() {
  find "$REPO_PATH" "${FIND_PRUNE[@]}" -o -mindepth 1 -maxdepth 4 -print
}

write_matching_paths_section() {
  local title="$1"
  local regex="$2"

  echo "## $title" >> "$OUTPUT_PATH"
  local matches
  matches="$(
    repo_find_files \
      | sed "s|^$REPO_PATH/||" \
      | grep -Ei "$regex" \
      | sort -u || true
  )"

  if [[ -n "$matches" ]]; then
    printf "%s\n" "$matches" >> "$OUTPUT_PATH"
  else
    echo "(none)" >> "$OUTPUT_PATH"
  fi
  echo >> "$OUTPUT_PATH"
}

write_manifest_contents_section() {
  local manifest_regex='/(package\.json|requirements\.txt|go\.mod|Cargo\.toml|pyproject\.toml|Gemfile|pom\.xml|composer\.json)$'
  echo "## Key Manifest Contents" >> "$OUTPUT_PATH"
  local files
  files="$(repo_find_files | grep -E "$manifest_regex" | sort || true)"

  if [[ -z "$files" ]]; then
    echo "(none)" >> "$OUTPUT_PATH"
    echo >> "$OUTPUT_PATH"
    return
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    echo "### $(relpath "$file")" >> "$OUTPUT_PATH"
    cat "$file" >> "$OUTPUT_PATH"
    echo >> "$OUTPUT_PATH"
  done <<< "$files"

  echo >> "$OUTPUT_PATH"
}

write_lockfile_section() {
  local lock_regex='/(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock|Cargo\.lock|Gemfile\.lock|composer\.lock|go\.sum)$'
  local truncate_lines=120

  echo "## Lock Files (Truncated)" >> "$OUTPUT_PATH"
  local files
  files="$(repo_find_files | grep -E "$lock_regex" | sort || true)"

  if [[ -z "$files" ]]; then
    echo "(none)" >> "$OUTPUT_PATH"
    echo >> "$OUTPUT_PATH"
    return
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local total_lines
    total_lines="$(wc -l < "$file" | awk '{print $1}')"
    echo "### $(relpath "$file")" >> "$OUTPUT_PATH"
    if (( total_lines > truncate_lines )); then
      head -n "$truncate_lines" "$file" >> "$OUTPUT_PATH"
      echo "... (truncated: showing first $truncate_lines of $total_lines lines)" >> "$OUTPUT_PATH"
    else
      cat "$file" >> "$OUTPUT_PATH"
    fi
    echo >> "$OUTPUT_PATH"
  done <<< "$files"

  echo >> "$OUTPUT_PATH"
}

write_config_paths_section() {
  local config_regex='(\.env($|\.)|(^|/)[^/]*config[^/]*\.(json|ya?ml|toml|ini|conf|cfg)$|(^|/)config\.(json|ya?ml|toml|ini|conf|cfg)$|(^|/)settings\.(json|ya?ml|toml|ini|conf|cfg)$|(^|/)docker-compose(\.[^/]+)?$|(^|/)\.editorconfig$|(^|/)tsconfig\.json$|(^|/)jsconfig\.json$|(^|/).*\.conf$|(^|/).*\.cfg$|(^|/).*\.ini$)'

  echo "## Config File Paths (No Contents)" >> "$OUTPUT_PATH"
  local matches
  matches="$(
    repo_find_files \
      | sed "s|^$REPO_PATH/||" \
      | grep -Ei "$config_regex" \
      | sort -u || true
  )"

  if [[ -n "$matches" ]]; then
    printf "%s\n" "$matches" >> "$OUTPUT_PATH"
  else
    echo "(none)" >> "$OUTPUT_PATH"
  fi
  echo >> "$OUTPUT_PATH"
}

write_extension_summary_section() {
  echo "## File Extension Summary" >> "$OUTPUT_PATH"
  local summary
  summary="$(
    repo_find_files | awk -F/ '
      {
        fname=$NF
        n=split(fname, parts, ".")
        if (n > 1 && parts[n] != "") {
          ext=tolower(parts[n])
        } else {
          ext="(no_ext)"
        }
        count[ext]++
      }
      END {
        for (ext in count) {
          printf "%7d %s\n", count[ext], ext
        }
      }
    ' | sort -nr
  )"

  if [[ -n "$summary" ]]; then
    printf "%s\n" "$summary" >> "$OUTPUT_PATH"
  else
    echo "(none)" >> "$OUTPUT_PATH"
  fi
  echo >> "$OUTPUT_PATH"
}

TOTAL_FILES="$(repo_find_files | wc -l | awk '{print $1}')"

{
  echo "# Repository Snapshot"
  echo "Generated At (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Repository: $REPO_PATH"
  echo
  echo "## Directory Tree (Depth 4)"
} > "$OUTPUT_PATH"

if command -v tree >/dev/null 2>&1; then
  if ! tree -a -L 4 -I "$TREE_IGNORE" "$REPO_PATH" >> "$OUTPUT_PATH" 2>/dev/null; then
    repo_find_depth4 | sed "s|^$REPO_PATH/||" | sort >> "$OUTPUT_PATH"
  fi
else
  repo_find_depth4 | sed "s|^$REPO_PATH/||" | sort >> "$OUTPUT_PATH"
fi

echo >> "$OUTPUT_PATH"

write_manifest_contents_section
write_lockfile_section
write_config_paths_section

write_matching_paths_section \
  "Files Matching Route/Controller/Handler/Resolver Patterns" \
  '(route|routes|controller|controllers|handler|handlers|resolver|resolvers)'

write_matching_paths_section \
  "Files Matching Model/Schema/Entity/Migration/Repository Patterns" \
  '(model|models|schema|schemas|entity|entities|migration|migrations|repository|repositories)'

write_matching_paths_section \
  "Files Matching Middleware/Interceptor/Guard Patterns" \
  '(middleware|interceptor|interceptors|guard|guards)'

write_matching_paths_section \
  "Files Matching Auth/Security/Token/JWT/OAuth Patterns" \
  '(auth|security|token|tokens|jwt|oauth)'

write_matching_paths_section \
  "Files Matching Service/Usecase/Worker/Job/Queue/Event Patterns" \
  '(service|services|usecase|usecases|worker|workers|job|jobs|queue|queues|event|events)'

write_matching_paths_section \
  "Test Files (*.test.*, *.spec.*, test_*, *_test.*)" \
  '(\.test\.|\.spec\.|(^|/)test_[^/]*|_test\.)'

write_extension_summary_section

{
  echo "## Total File Count"
  echo "$TOTAL_FILES"
} >> "$OUTPUT_PATH"

echo "Snapshot written: $OUTPUT_PATH"
