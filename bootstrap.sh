#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [--install-python-tools]

Options:
  --install-python-tools   Install semgrep, lizard, and pip-audit via pip3
  -h, --help               Show this help message
EOF
}

INSTALL_PYTHON_TOOLS=false

case "${1:-}" in
  "")
    ;;
  --install-python-tools)
    INSTALL_PYTHON_TOOLS=true
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

required_missing=0

check_required() {
  local cmd="$1"
  local install_hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Missing required tool: $cmd ($install_hint)"
    required_missing=1
  fi
}

install_python_tool() {
  local package="$1"
  if command -v "$package" >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    echo "⚠️  pip3 not found; cannot auto-install $package"
    return 1
  fi

  echo "Installing $package via pip3..."
  if ! pip3 install "$package" --break-system-packages; then
    echo "⚠️  Failed to install $package with --break-system-packages; retrying without it..."
    pip3 install "$package"
  fi
}

echo "Checking required tools..."
check_required "claude" "install Claude Code CLI"
check_required "jq" "brew install jq / apt install jq"
check_required "python3" "install Python 3"

if [[ "$INSTALL_PYTHON_TOOLS" == "true" ]]; then
  install_python_tool "semgrep" || true
  install_python_tool "lizard" || true
  install_python_tool "pip-audit" || true
fi

echo
echo "Optional install guidance:"
echo "  gitleaks:"
echo "    macOS: brew install gitleaks"
echo "    Linux: download from https://github.com/gitleaks/gitleaks/releases"
echo "  trufflehog:"
echo "    macOS: brew install trufflehog"
echo "    Linux: download from https://github.com/trufflesecurity/trufflehog/releases"
echo "  osv-scanner:"
echo "    macOS: brew install osv-scanner"
echo "    Linux: download from https://github.com/google/osv-scanner/releases"
echo "  tree (optional):"
echo "    macOS: brew install tree"
echo "    Linux: apt install tree / yum install tree"

echo
echo "Tool versions:"
echo "  claude:       $(claude --version 2>/dev/null || echo 'NOT FOUND')"
echo "  semgrep:      $(semgrep --version 2>/dev/null || echo 'NOT FOUND — run: pip install semgrep')"
echo "  lizard:       $(lizard --version 2>/dev/null || echo 'NOT FOUND — run: pip install lizard')"
echo "  pip-audit:    $(pip-audit --version 2>/dev/null || echo 'NOT FOUND — run: pip install pip-audit')"
echo "  gitleaks:     $(gitleaks version 2>/dev/null || echo 'NOT FOUND — see instructions above')"
echo "  trufflehog:   $(trufflehog --version 2>/dev/null || echo 'NOT FOUND — see instructions above')"
echo "  osv-scanner:  $(osv-scanner --version 2>/dev/null || echo 'NOT FOUND — see instructions above')"
echo "  jq:           $(jq --version 2>/dev/null || echo 'NOT FOUND — run: brew install jq')"
echo "  tree:         $(tree --version 2>/dev/null || echo 'NOT FOUND (optional)')"

echo
if [[ "$required_missing" -ne 0 ]]; then
  echo "Bootstrap check failed: one or more required tools are missing."
  exit 1
fi

echo "Bootstrap check complete."
