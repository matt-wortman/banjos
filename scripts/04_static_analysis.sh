#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/04_static_analysis.sh <repo_path> <static_output_dir> <skip_static> <skip_secrets>
EOF
}

if [[ $# -ne 4 ]]; then
  usage >&2
  exit 2
fi

REPO_PATH="$1"
STATIC_OUTPUT_DIR="$2"
SKIP_STATIC="$3"
SKIP_SECRETS="$4"

if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: repo_path is not a directory: $REPO_PATH" >&2
  exit 2
fi

if [[ "$SKIP_STATIC" != "true" && "$SKIP_STATIC" != "false" ]]; then
  echo "Error: skip_static must be true|false: $SKIP_STATIC" >&2
  exit 2
fi

if [[ "$SKIP_SECRETS" != "true" && "$SKIP_SECRETS" != "false" ]]; then
  echo "Error: skip_secrets must be true|false: $SKIP_SECRETS" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: required command not found: jq" >&2
  exit 2
fi

mkdir -p "$STATIC_OUTPUT_DIR"

SEMGREP_BIN="${SEMGREP_BIN:-semgrep}"
GITLEAKS_BIN="${GITLEAKS_BIN:-gitleaks}"
TRUFFLEHOG_BIN="${TRUFFLEHOG_BIN:-trufflehog}"
OSV_SCANNER_BIN="${OSV_SCANNER_BIN:-osv-scanner}"
LIZARD_BIN="${LIZARD_BIN:-lizard}"

LIZARD_CCN_THRESHOLD="${LIZARD_CCN_THRESHOLD:-10}"
LIZARD_LENGTH_THRESHOLD="${LIZARD_LENGTH_THRESHOLD:-100}"
LIZARD_PARAMS_THRESHOLD="${LIZARD_PARAMS_THRESHOLD:-6}"

SEMGREP_OUTPUT="$STATIC_OUTPUT_DIR/semgrep.json"
GITLEAKS_OUTPUT="$STATIC_OUTPUT_DIR/gitleaks.json"
TRUFFLEHOG_OUTPUT="$STATIC_OUTPUT_DIR/trufflehog.json"
OSV_OUTPUT="$STATIC_OUTPUT_DIR/osv.json"
LIZARD_OUTPUT="$STATIC_OUTPUT_DIR/lizard.json"

write_json_file() {
  local output_path="$1"
  local json_content="$2"
  printf "%s\n" "$json_content" > "$output_path"
}

write_skipped_json() {
  local output_path="$1"
  local reason="$2"
  write_json_file "$output_path" "{\"skipped\":true,\"reason\":\"$reason\"}"
}

run_semgrep() {
  if ! command -v "$SEMGREP_BIN" >/dev/null 2>&1; then
    echo "Warning: $SEMGREP_BIN not installed; writing skipped Semgrep artifact." >&2
    write_skipped_json "$SEMGREP_OUTPUT" "tool_not_installed"
    return 0
  fi

  local args=(
    scan
    --config "p/default"
    --config "p/owasp-top-ten"
    --json
    --output "$SEMGREP_OUTPUT"
    "$REPO_PATH"
  )
  if [[ "$SKIP_SECRETS" == "false" ]]; then
    args=(scan --config "p/default" --config "p/owasp-top-ten" --config "p/secrets" --json --output "$SEMGREP_OUTPUT" "$REPO_PATH")
  fi

  if ! "$SEMGREP_BIN" "${args[@]}" >/dev/null 2>&1; then
    if [[ -s "$SEMGREP_OUTPUT" ]] && jq empty "$SEMGREP_OUTPUT" >/dev/null 2>&1; then
      echo "Semgrep completed with findings/warnings and produced JSON output."
      return 0
    fi
    echo "Warning: Semgrep run failed; writing error artifact." >&2
    write_json_file "$SEMGREP_OUTPUT" '{"error":"tool_execution_failed","tool":"semgrep"}'
    return 0
  fi

  if ! jq empty "$SEMGREP_OUTPUT" >/dev/null 2>&1; then
    echo "Warning: Semgrep output invalid JSON; writing error artifact." >&2
    write_json_file "$SEMGREP_OUTPUT" '{"error":"invalid_json_output","tool":"semgrep"}'
  fi
}

run_gitleaks() {
  if [[ "$SKIP_SECRETS" == "true" ]]; then
    write_skipped_json "$GITLEAKS_OUTPUT" "skip_secrets"
    return 0
  fi

  if ! command -v "$GITLEAKS_BIN" >/dev/null 2>&1; then
    echo "Warning: $GITLEAKS_BIN not installed; writing skipped Gitleaks artifact." >&2
    write_skipped_json "$GITLEAKS_OUTPUT" "tool_not_installed"
    return 0
  fi

  local args=(
    detect
    --source "$REPO_PATH"
    --report-format json
    --report-path "$GITLEAKS_OUTPUT"
  )
  if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    args+=(--no-git)
  fi

  if ! "$GITLEAKS_BIN" "${args[@]}" >/dev/null 2>&1; then
    if [[ -s "$GITLEAKS_OUTPUT" ]] && jq empty "$GITLEAKS_OUTPUT" >/dev/null 2>&1; then
      echo "Gitleaks completed with findings and produced JSON output."
      return 0
    fi
    echo "Warning: Gitleaks run failed; writing error artifact." >&2
    write_json_file "$GITLEAKS_OUTPUT" '{"error":"tool_execution_failed","tool":"gitleaks"}'
    return 0
  fi

  if ! jq empty "$GITLEAKS_OUTPUT" >/dev/null 2>&1; then
    echo "Warning: Gitleaks output invalid JSON; writing error artifact." >&2
    write_json_file "$GITLEAKS_OUTPUT" '{"error":"invalid_json_output","tool":"gitleaks"}'
  fi
}

run_trufflehog() {
  if [[ "$SKIP_SECRETS" == "true" ]]; then
    write_skipped_json "$TRUFFLEHOG_OUTPUT" "skip_secrets"
    return 0
  fi

  if ! command -v "$TRUFFLEHOG_BIN" >/dev/null 2>&1; then
    echo "Warning: $TRUFFLEHOG_BIN not installed; writing skipped TruffleHog artifact." >&2
    write_skipped_json "$TRUFFLEHOG_OUTPUT" "tool_not_installed"
    return 0
  fi

  local raw_output
  local cmd_status=0
  raw_output="$(mktemp)"

  if "$TRUFFLEHOG_BIN" filesystem --directory "$REPO_PATH" --json --no-verification > "$raw_output" 2>/dev/null; then
    cmd_status=0
  else
    cmd_status=$?
  fi

  if [[ -s "$raw_output" ]] && jq -s '.' < "$raw_output" > "$TRUFFLEHOG_OUTPUT" 2>/dev/null; then
    rm -f "$raw_output"
    if (( cmd_status != 0 )); then
      echo "TruffleHog completed with findings/warnings and produced JSON output."
    fi
    return 0
  fi

  rm -f "$raw_output"
  if (( cmd_status != 0 )); then
    echo "Warning: TruffleHog run failed; writing error artifact." >&2
    write_json_file "$TRUFFLEHOG_OUTPUT" '{"error":"tool_execution_failed","tool":"trufflehog"}'
    return 0
  fi

  echo "Warning: TruffleHog output invalid JSON; writing error artifact." >&2
  write_json_file "$TRUFFLEHOG_OUTPUT" '{"error":"invalid_json_output","tool":"trufflehog"}'
}

run_osv() {
  if command -v "$OSV_SCANNER_BIN" >/dev/null 2>&1; then
    if ! "$OSV_SCANNER_BIN" --format json --output "$OSV_OUTPUT" "$REPO_PATH" >/dev/null 2>&1; then
      if [[ -s "$OSV_OUTPUT" ]] && jq empty "$OSV_OUTPUT" >/dev/null 2>&1; then
        echo "OSV-Scanner completed with findings and produced JSON output."
        return 0
      fi
      echo "Warning: OSV-Scanner failed; writing error artifact." >&2
      write_json_file "$OSV_OUTPUT" '{"error":"tool_execution_failed","tool":"osv-scanner"}'
      return 0
    fi

    if ! jq empty "$OSV_OUTPUT" >/dev/null 2>&1; then
      echo "Warning: OSV-Scanner output invalid JSON; writing error artifact." >&2
      write_json_file "$OSV_OUTPUT" '{"error":"invalid_json_output","tool":"osv-scanner"}'
    fi
    return 0
  fi

  local npm_tmp
  local pip_tmp
  local npm_payload
  local pip_payload
  local ran_fallback=false

  npm_tmp="$(mktemp)"
  pip_tmp="$(mktemp)"
  trap 'rm -f "$npm_tmp" "$pip_tmp"' RETURN

  if command -v npm >/dev/null 2>&1 && [[ -f "$REPO_PATH/package.json" ]]; then
    ran_fallback=true
    if ! (cd "$REPO_PATH" && npm audit --json > "$npm_tmp" 2>/dev/null); then
      if [[ ! -s "$npm_tmp" ]] || ! jq empty "$npm_tmp" >/dev/null 2>&1; then
        printf '{"error":"tool_execution_failed","tool":"npm-audit"}\n' > "$npm_tmp"
      fi
    fi
  else
    printf '{"skipped":true,"reason":"npm_audit_not_applicable"}\n' > "$npm_tmp"
  fi

  if command -v pip-audit >/dev/null 2>&1 && ( [[ -f "$REPO_PATH/requirements.txt" ]] || [[ -f "$REPO_PATH/pyproject.toml" ]] ); then
    ran_fallback=true
    if ! (cd "$REPO_PATH" && pip-audit --format json > "$pip_tmp" 2>/dev/null); then
      if [[ ! -s "$pip_tmp" ]] || ! jq empty "$pip_tmp" >/dev/null 2>&1; then
        printf '{"error":"tool_execution_failed","tool":"pip-audit"}\n' > "$pip_tmp"
      fi
    fi
  else
    printf '{"skipped":true,"reason":"pip_audit_not_applicable"}\n' > "$pip_tmp"
  fi

  if [[ "$ran_fallback" == "false" ]]; then
    write_skipped_json "$OSV_OUTPUT" "tool_not_installed"
    return 0
  fi

  npm_payload="$(cat "$npm_tmp")"
  pip_payload="$(cat "$pip_tmp")"
  jq -n \
    --argjson npm "$npm_payload" \
    --argjson pip "$pip_payload" \
    '{
      fallback: true,
      source: "osv_scanner_not_installed",
      npm_audit: $npm,
      pip_audit: $pip
    }' > "$OSV_OUTPUT"
}

run_lizard() {
  if ! command -v "$LIZARD_BIN" >/dev/null 2>&1; then
    echo "Warning: $LIZARD_BIN not installed; writing skipped Lizard artifact." >&2
    write_skipped_json "$LIZARD_OUTPUT" "tool_not_installed"
    return 0
  fi

  if ! "$LIZARD_BIN" "$REPO_PATH" \
      --language python,javascript,typescript,java,go,ruby,swift,kotlin,rust,cpp \
      --CCN "$LIZARD_CCN_THRESHOLD" \
      --length "$LIZARD_LENGTH_THRESHOLD" \
      --arguments "$LIZARD_PARAMS_THRESHOLD" \
      --output_file "$LIZARD_OUTPUT" \
      --json >/dev/null 2>&1; then
    if [[ -s "$LIZARD_OUTPUT" ]] && jq empty "$LIZARD_OUTPUT" >/dev/null 2>&1; then
      echo "Lizard completed with threshold warnings and produced JSON output."
      return 0
    fi
    echo "Warning: Lizard run failed; writing error artifact." >&2
    write_json_file "$LIZARD_OUTPUT" '{"error":"tool_execution_failed","tool":"lizard"}'
    return 0
  fi

  if ! jq empty "$LIZARD_OUTPUT" >/dev/null 2>&1; then
    echo "Warning: Lizard output invalid JSON; writing error artifact." >&2
    write_json_file "$LIZARD_OUTPUT" '{"error":"invalid_json_output","tool":"lizard"}'
  fi
}

ensure_expected_artifacts() {
  local artifact
  local failed=0
  for artifact in \
    "$SEMGREP_OUTPUT" \
    "$GITLEAKS_OUTPUT" \
    "$TRUFFLEHOG_OUTPUT" \
    "$OSV_OUTPUT" \
    "$LIZARD_OUTPUT"
  do
    if [[ ! -f "$artifact" ]]; then
      echo "Error: missing required static artifact: $artifact" >&2
      failed=1
      continue
    fi
    if ! jq empty "$artifact" >/dev/null 2>&1; then
      echo "Error: static artifact is not valid JSON: $artifact" >&2
      failed=1
    fi
  done
  return "$failed"
}

if [[ "$SKIP_STATIC" == "true" ]]; then
  echo "Static analysis skipped by flag; writing skipped artifacts."
  write_skipped_json "$SEMGREP_OUTPUT" "skip_static"
  write_skipped_json "$GITLEAKS_OUTPUT" "skip_static"
  write_skipped_json "$TRUFFLEHOG_OUTPUT" "skip_static"
  write_skipped_json "$OSV_OUTPUT" "skip_static"
  write_skipped_json "$LIZARD_OUTPUT" "skip_static"
  if ! ensure_expected_artifacts; then
    exit 1
  fi
  echo "Phase 4 complete: skipped artifacts written to $STATIC_OUTPUT_DIR"
  exit 0
fi

echo "Running Phase 4 static analysis..."

run_semgrep &
pid_semgrep="$!"
run_gitleaks &
pid_gitleaks="$!"
run_trufflehog &
pid_trufflehog="$!"
run_osv &
pid_osv="$!"
run_lizard &
pid_lizard="$!"

phase_failed=0
for pid in "$pid_semgrep" "$pid_gitleaks" "$pid_trufflehog" "$pid_osv" "$pid_lizard"; do
  if ! wait "$pid"; then
    phase_failed=1
  fi
done

if ! ensure_expected_artifacts; then
  exit 1
fi

if (( phase_failed != 0 )); then
  echo "Error: one or more static analysis workers failed unexpectedly." >&2
  exit 1
fi

echo "Phase 4 complete: static artifacts written to $STATIC_OUTPUT_DIR"
