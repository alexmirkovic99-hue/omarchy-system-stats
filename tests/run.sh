#!/bin/bash
# Runs every test. All of them use temporary files and fake hyprctl/omarchy
# commands; none reads or writes your real Hyprland or Omarchy config.
#   tests/run.sh
set -uo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failed=()

for tool in bash jq node flock; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing test dependency: $tool" >&2; exit 2; }
done

run() {
  echo "== $1"
  if "${@:2}"; then echo "   ok"; else failed+=("$1"); echo "   FAILED"; fi
}

run "model (parsing, labels, palettes, contrast, hotkey capture)" node "$DIR/test-model.js"
run "collector (Intel/AMD/NVIDIA fixtures)" node "$DIR/test-stats.js"
run "hotkey.sh (bindings.lua block)" "$DIR/test-hotkey.sh"
run "toggle.sh (show/hide/delete)" "$DIR/test-toggle.sh"
run "default hotkeys are not Omarchy defaults" "$DIR/test-defaults.sh"
run "manifest is valid JSON with the expected entry point" \
  jq -e '.schemaVersion == 1 and (.id | test("^[a-z0-9][a-z0-9._-]*$")) and .entryPoints.barWidget == "SystemStats.qml"' "$DIR/../manifest.json"

if command -v shellcheck >/dev/null 2>&1; then
  run "shellcheck" shellcheck "$DIR/../hotkey.sh" "$DIR/../toggle.sh" "$DIR"/*.sh
else
  echo "== shellcheck: not installed, skipped"
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all tests passed"
