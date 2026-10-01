#!/bin/bash
# Checks that none of this plugin's default hotkey candidates (hotkey.conf) is a
# chord Omarchy binds out of the box, so they are never even considered.
# Run: tests/test-defaults.sh (skips when Omarchy is not installed)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY_HYPR=${OMARCHY_PATH:-/usr/share/omarchy}/default/hypr
# shellcheck disable=SC1091
source "$HERE/hotkey.conf"

# (modmask, KEY) of a chord such as "SUPER + CTRL + W", or "SUPER CTRL + W".
normalise() {
  local chord=$1 mask=0 key=${1##*+} part
  key=${key// /}
  for part in ${chord%+*}; do
    case ${part//+/} in
      SHIFT) mask=$((mask | 1)) ;;
      CTRL | CONTROL) mask=$((mask | 4)) ;;
      ALT) mask=$((mask | 8)) ;;
      SUPER | MOD4 | WIN) mask=$((mask | 64)) ;;
    esac
  done
  echo "$mask ${key^^}"
}

if [[ ! -d $OMARCHY_HYPR ]]; then
  echo "SKIP: $OMARCHY_HYPR not found (Omarchy not installed here)"
  exit 0
fi

declare -A taken
while IFS= read -r chord; do
  taken[$(normalise "$chord")]=$chord
done < <(grep -rhoE '(o\.bind|hl\.bind)\(\s*"[^"]+"' "$OMARCHY_HYPR" | sed -E 's/^[^"]*"//; s/"$//')

fail=0
ALL=()
declare -A seen
for name in "${ACTIONS[@]}"; do
  declare -n list="${name}_DEFAULTS"
  for candidate in "${list[@]}"; do
    ALL+=("$candidate")
    # the same chord must not be offered to two different hotkeys
    if [[ -n ${seen[$(normalise "$candidate")]:-} ]]; then
      echo "FAIL: '$candidate' is a default of both ${seen[$(normalise "$candidate")]} and $name"
      fail=1
    fi
    seen[$(normalise "$candidate")]=$name
  done
  unset -n list
done
DEFAULTS=("${ALL[@]}")
for candidate in "${DEFAULTS[@]}"; do
  if [[ -n ${taken[$(normalise "$candidate")]:-} ]]; then
    echo "FAIL: default '$candidate' is already an Omarchy default binding (${taken[$(normalise "$candidate")]})"
    fail=1
  fi
  [[ $candidate =~ ^((SUPER|CTRL|SHIFT|ALT)\ \+\ ){1,4}[A-Z0-9]{1,16}$ ]] || { echo "FAIL: '$candidate' is not a valid chord"; fail=1; }
done
echo "checked ${#DEFAULTS[@]} defaults against ${#taken[@]} Omarchy bindings"
exit $fail
