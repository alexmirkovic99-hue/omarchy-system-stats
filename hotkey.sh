#!/bin/bash
# Optional hotkey for the System stats widget.
#
# Two hotkeys can be managed, each ONE marked block at the end of
# ~/.config/hypr/bindings.lua:
#
#   toggle  hides the stats into the small button, or shows them again
#   menu    opens the widget's menu (palette, hotkeys, collapse)
#
#   -- >>> <plugin-id> hotkey (managed by the System stats plugin; ...) >>>
#   o.bind("SUPER + CTRL + M", "Expand or collapse System stats", "bash '<plugin dir>/toggle.sh' toggle")
#   -- <<< <plugin-id> hotkey <<<
#
# (the menu hotkey's block says "hotkey-menu" in the marker lines). Everything
# below takes an optional first word, `toggle` or `menu`; without it, `toggle`.
#
# Two modes per hotkey, chosen by the user when pressing Add in the panel
# (MANUAL is the default):
#   MANUAL  the user presses their own shortcut; nothing is written unless the
#           user does that, presses Clear, or runs this script by hand
#   AUTO    the user has asked for it: a free default hotkey is added
#           automatically, and moved to the next free default if another
#           shortcut takes it. A shortcut the user set themselves is never changed.
# Everything outside the block is kept byte for byte; add followed by clear
# restores the original file.
#
#   hotkey.sh [menu] get      print the current chord (nothing if none)
#   hotkey.sh check           print what else uses the current chord (nothing if free)
#   hotkey.sh set "<CHORD>"   a chosen shortcut, e.g. "SUPER + ALT + M" (needs a modifier)
#   hotkey.sh set-default     "Add": write the first free chord listed in hotkey.conf
#   hotkey.sh clear           remove the block
#   hotkey.sh mode            print the mode (manual or auto)
#   hotkey.sh mode auto       switch to AUTO (and add a default hotkey if there is none)
#   hotkey.sh mode manual     switch to MANUAL (an existing hotkey is kept)
#   hotkey.sh ensure          AUTO only: add or move the default hotkeys (both); does nothing in MANUAL
#
# State (the mode and whether the hotkey came from a default or from the user)
# is one small file: ${XDG_STATE_HOME:-~/.local/state}/<plugin-id>/hotkey.json
#
# Exit codes: 0 ok, 1 usage, 2 invalid chord, 3 chord already used,
# 4 Hyprland rejected the change (it was undone), 5 no default is free,
# 6 unsafe plugin path or config, 7 bindings.lua not found,
# 8 the marked block is damaged (nothing changed), 9 conflicts cannot be
# checked (Hyprland not running, hyprctl or jq missing) or the file is locked.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "$HERE/hotkey.conf"

die() {
  echo "$2" >&2
  exit "$1"
}

command -v jq >/dev/null 2>&1 || die 9 "The hotkey needs jq, which was not found."
PLUGIN_ID=$(jq -r '.id // empty' "$HERE/manifest.json" 2>/dev/null || true)
[[ $PLUGIN_ID =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die 6 "Cannot read the plugin id from manifest.json."
# These strings end up inside Lua and shell quotes, so only plain characters
# are accepted; anything else is refused rather than escaped.
[[ $HERE =~ ^[A-Za-z0-9._/@+-]+$ ]] ||
  die 6 "The plugin folder path has characters that cannot be written safely into bindings.lua: $HERE"

BINDINGS=${BINDINGS_FILE:-$HOME/.config/hypr/bindings.lua}
HYPR=${HYPRCTL:-hyprctl}

# Picks which hotkey the rest of the script works on: sets ACTION, DESC,
# DEFAULTS, COMMAND and the marker lines of its block.
select_action() {
  local suffix d a
  ACTION=$1
  case $ACTION in
    toggle)
      suffix=""
      COMMAND="bash '$HERE/toggle.sh' toggle"
      ;;
    menu)
      suffix="-menu"
      COMMAND="omarchy-shell shell toggle '$PLUGIN_ID' '{}'"
      ;;
    *) die 1 "Unknown hotkey: $1 (expected toggle or menu)" ;;
  esac
  d="${ACTION}_DESC"
  a="${ACTION}_DEFAULTS[@]"
  DESC=${!d:-}
  DEFAULTS=("${!a}")
  [[ -n $DESC && $DESC =~ ^[A-Za-z0-9\ .,\(\)-]+$ ]] || die 6 "hotkey.conf: ${ACTION}_DESC is missing or has unsupported characters."
  BEGIN="-- >>> $PLUGIN_ID hotkey$suffix (managed by the System stats plugin; change or clear it from its panel) >>>"
  END="-- <<< $PLUGIN_ID hotkey$suffix <<<"
}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/$PLUGIN_ID
STATE_FILE=$STATE_DIR/hotkey.json
NOTIFY=${NOTIFY_CMD:-omarchy-notification-send}

# Advisory lock so two edits of bindings.lua (two clicks, or another tool that
# uses the same lock name) never interleave. Owner-only runtime directory.
RUNTIME=${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}
mkdir -p "$RUNTIME"
exec 9>"$RUNTIME/omarchy-hotkeys.lock"
flock -w 10 9 || die 9 "bindings.lua is being edited by another program; try again."

TMP_FILES=()
cleanup() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then rm -f -- "${TMP_FILES[@]}"; fi
}
trap cleanup EXIT

# The real file. A symlinked bindings.lua (dotfiles) is edited at its target
# so the link survives.
target() {
  local t
  t=$(readlink -f -- "$BINDINGS" 2>/dev/null) || return 1
  [[ -n $t && -f $t ]] || return 1
  printf '%s\n' "$t"
}

has_block() { grep -Fxq -- "$BEGIN" "$1" || grep -Fxq -- "$END" "$1"; }

# Markers must come in BEGIN/END pairs, in order. Otherwise nothing is edited:
# guessing where a block ends could delete the user's own bindings.
block_intact() {
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { if (on) bad = 1; on = 1; next }
    $0 == e { if (!on) bad = 1; on = 0 }
    END { exit (bad || on) ? 1 : 0 }' "$1"
}

current_chord() {
  local t
  t=$(target) || return 0
  awk -v b="$BEGIN" -v e="$END" '$0 == b { on = 1; next } $0 == e { on = 0 } on' "$t" |
    sed -n 's/^o\.bind("\([^"]*\)".*/\1/p' | awk 'NR == 1'
}

# The file without our block. The single blank line written before the block
# is dropped with it, so add + remove is an exact round trip.
without_block() {
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1; if (blank > 0) blank--; next }
    skip { if ($0 == e) skip = 0; next }
    /^$/ { blank++; next }
    { while (blank > 0) { print ""; blank-- } print }
    END { while (blank > 0) { print ""; blank-- } }' "$1"
}

modmask() {
  local mask=0 part
  local IFS='+'
  for part in $1; do
    part=${part// /}
    case $part in
      SHIFT) mask=$((mask | 1)) ;;
      CTRL) mask=$((mask | 4)) ;;
      ALT) mask=$((mask | 8)) ;;
      SUPER) mask=$((mask | 64)) ;;
    esac
  done
  echo "$mask"
}

# 1-4 distinct modifiers, then one key name (must match Model.validChord).
valid_chord() {
  [[ $1 =~ ^((SUPER|CTRL|SHIFT|ALT)\ \+\ ){1,4}[A-Z0-9]{1,16}$ ]] || return 1
  local mods=${1% + *}
  [[ $(tr -s ' +' '\n' <<<"$mods" | sort | uniq -d) == "" ]]
}

# Prints what else uses a chord (empty when free). Returns 9 when Hyprland's
# bindings cannot be read, so callers refuse instead of assuming "free".
# Hyprland reports bindings made by key code (Omarchy's workspace digits,
# resize keys, ...) with an empty key name; for anything but a letter or an
# F-key such a binding on the same modifiers counts as a possible conflict.
# $2 = "true" when the chord is the one in our own block, whose binding is
# then not reported as a conflict with itself.
conflict_for() {
  local chord=$1 own=${2:-false} key=${1##* } binds letter=false
  command -v "$HYPR" >/dev/null 2>&1 || return 9
  binds=$("$HYPR" binds -j 2>/dev/null) || return 9
  jq -e 'type == "array"' <<<"$binds" >/dev/null 2>&1 || return 9
  [[ $key =~ ^([A-Z]|F[0-9]{1,2})$ ]] && letter=true
  jq -r --argjson mask "$(modmask "$chord")" --arg key "$key" --arg desc "$DESC" \
    --argjson letter "$letter" --argjson own "$own" '
    [ .[]
      | select(.modmask == $mask)
      | select(((.key // "") | ascii_downcase) == ($key | ascii_downcase)
               or ($letter | not) and (.key // "") == "")
      | select(($own and (.description // "") == $desc) | not) ]
    | first
    | if . == null then empty
      else ((if (.description // "") != "" then .description else (.dispatcher // "another binding") end)
            + (if (.key // "") == "" then " (bound by key code)" else "" end))
      end' <<<"$binds"
}

errors() {
  if command -v "$HYPR" >/dev/null 2>&1; then "$HYPR" configerrors 2>/dev/null || true; fi
}

reload_or_rollback() { # target backup errors-before
  local after rb
  command -v "$HYPR" >/dev/null 2>&1 || return 0
  "$HYPR" reload >/dev/null 2>&1 || true
  sleep 0.5
  after=$(errors)
  if [[ -n $after && $after != "$3" ]]; then
    rb=$(mktemp "$1.XXXXXX")
    TMP_FILES+=("$rb")
    cp -p -- "$2" "$rb"
    mv -f -- "$rb" "$1"
    "$HYPR" reload >/dev/null 2>&1 || true
    die 4 "Hyprland rejected the change, so it was undone: $after"
  fi
}

write_block() { # chord, or "" to remove the block
  local chord=$1 t before backup tmp
  t=$(target) || die 7 "$BINDINGS was not found; nothing was changed."
  block_intact "$t" ||
    die 8 "The marked hotkey block in $t is incomplete (a marker line was removed or duplicated). Nothing was changed; delete the block by hand."
  before=$(errors)
  backup=$(mktemp "$RUNTIME/bindings.lua.backup.XXXXXX")
  TMP_FILES+=("$backup")
  cp -p -- "$t" "$backup"
  tmp=$(mktemp "$t.XXXXXX")
  TMP_FILES+=("$tmp")
  {
    without_block "$t"
    if [[ -n $chord ]]; then
      printf '\n%s\n' "$BEGIN"
      printf 'o.bind("%s", "%s", "%s")\n' "$chord" "$DESC" "$COMMAND"
      printf '%s\n' "$END"
    fi
  } >"$tmp"
  chmod --reference="$t" -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$t"
  reload_or_rollback "$t" "$backup" "$before"
}

# Checks a chord and writes it. Exits on any problem. $2 = who chose it:
# "user" (Custom) or "default" (Add).
set_chord() {
  local chord=$1 origin=${2:-user} own=false clash rc=0
  valid_chord "$chord" ||
    die 2 "Not a valid shortcut: it needs one to four different modifiers (Super, Ctrl, Shift, Alt) and a key."
  [[ $chord == "$(current_chord)" ]] && own=true
  clash=$(conflict_for "$chord" "$own") || rc=$?
  [[ $rc -eq 0 ]] ||
    die 9 "Cannot check whether $chord is free (is Hyprland running, and are hyprctl and jq installed?). Nothing was changed."
  [[ -z $clash ]] || die 3 "$chord is already used by: $clash"
  write_block "$chord"
  state_set origin "\"$origin\"" cleared false
  echo "$chord"
}

# ---- mode and origin (see the header) -----------------------------------------
state_value() { # key default   (of the selected hotkey)
  local v
  v=$(jq -r --arg a "$ACTION" --arg k "$1" '.[$a][$k] // empty | tostring' "$STATE_FILE" 2>/dev/null || true)
  printf '%s\n' "${v:-$2}"
}

state_set() { # key json-value ...   (pairs, of the selected hotkey)
  local base tmp
  base=$(cat "$STATE_FILE" 2>/dev/null || true)
  jq -e 'type == "object"' <<<"$base" >/dev/null 2>&1 || base='{}'
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.hotkey.XXXXXX")
  TMP_FILES+=("$tmp")
  while [[ $# -ge 2 ]]; do
    base=$(jq -c --arg a "$ACTION" --arg k "$1" --argjson v "$2" '.[$a] = (((.[$a] // {}) | if type == "object" then . else {} end) | .[$k] = $v)' <<<"$base")
    shift 2
  done
  printf '%s\n' "$base" >"$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

mode_get() {
  local m
  m=$(state_value mode manual)
  [[ $m == auto ]] && echo auto || echo manual
}

notify() {
  command -v "$NOTIFY" >/dev/null 2>&1 || return 0
  "$NOTIFY" "System stats" "$1" >/dev/null 2>&1 || true
}

# First default nothing else uses, skipping $1 (the chord being replaced).
# Returns 5 when none is free, 9 when conflicts cannot be checked.
free_default() {
  local candidate clash rc own current
  current=$(current_chord)
  for candidate in "${DEFAULTS[@]}"; do
    [[ $candidate == "${1:-}" ]] && continue
    own=false
    [[ $candidate == "$current" ]] && own=true
    rc=0
    clash=$(conflict_for "$candidate" "$own") || rc=$?
    [[ $rc -eq 0 ]] || return 9
    if [[ -z $clash ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 5
}

# AUTO only. Adds a default hotkey when there is none (unless the user cleared
# it), and moves a default that another shortcut has taken. A chord the user set
# is never touched.
ensure() {
  [[ $(mode_get) == auto ]] || return 0
  local chord origin pick rc clash
  chord=$(current_chord)
  if [[ -z $chord ]]; then
    [[ $(state_value cleared false) == true ]] && return 0
    rc=0
    pick=$(free_default "") || rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    write_block "$pick"
    state_set origin '"default"' cleared false
    notify "$DESC: hotkey $pick added. It is listed in the keybindings menu (SUPER + K); change or clear it from the widget's panel."
    echo "$pick"
    return 0
  fi
  origin=$(state_value origin "")
  [[ $origin == default ]] || return 0
  rc=0
  clash=$(conflict_for "$chord" true) || rc=$?
  [[ $rc -eq 0 && -n $clash ]] || return 0
  rc=0
  pick=$(free_default "$chord") || rc=$?
  if [[ $rc -eq 0 ]]; then
    write_block "$pick"
    state_set origin '"default"' cleared false
    notify "$DESC: hotkey moved to $pick, because $chord is now used by another shortcut."
    echo "$pick"
    return 0
  fi
  [[ $rc -eq 5 ]] || return "$rc"
  write_block ""
  state_set origin '""' cleared true
  notify "$DESC: no default hotkey is free any more, so it was removed. Add one from the widget's panel."
  return 5
}

action=""
case "${1:-}" in
  toggle | menu)
    action=$1
    shift
    ;;
esac

# `ensure` without a hotkey name looks after every hotkey (AUTO ones only).
if [[ ${1:-} == ensure && -z $action ]]; then
  worst=0
  for name in "${ACTIONS[@]}"; do
    select_action "$name"
    rc=0
    ensure || rc=$?
    [[ $rc -eq 0 ]] || worst=$rc
  done
  exit "$worst"
fi

select_action "${action:-toggle}"

case "${1:-}" in
  get) current_chord ;;
  check)
    chord=$(current_chord)
    [[ -n $chord ]] || exit 0
    rc=0
    clash=$(conflict_for "$chord" true) || rc=$?
    [[ $rc -eq 0 ]] || die 9 "Cannot check the hotkey: Hyprland's bindings could not be read."
    [[ -z $clash ]] || echo "$chord is also used by: $clash"
    ;;
  set) set_chord "${2:-}" user ;;
  set-default)
    rc=0
    pick=$(free_default "") || rc=$?
    case $rc in
      0) set_chord "$pick" default ;;
      5) die 5 "None of the default shortcuts is free. Press Custom and choose one." ;;
      *) die 9 "Cannot check which shortcuts are free (is Hyprland running, and are hyprctl and jq installed?). Nothing was changed." ;;
    esac
    ;;
  clear)
    t=$(target) || exit 0
    if has_block "$t"; then write_block ""; fi
    state_set origin '""' cleared true
    ;;
  mode)
    case "${2:-}" in
      "") mode_get ;;
      manual) state_set mode '"manual"'; echo manual ;;
      auto)
        # Choosing AUTO is the request to add a default hotkey now.
        state_set mode '"auto"' cleared false
        rc=0
        ensure || rc=$?
        case $rc in
          0) echo auto ;;
          5) die 5 "AUTO is on, but none of the default shortcuts is free. Press Custom and choose one." ;;
          9) die 9 "AUTO is on, but conflicts cannot be checked (is Hyprland running, and are hyprctl and jq installed?). Nothing was changed." ;;
          *) exit "$rc" ;;
        esac
        ;;
      *) die 1 "Usage: hotkey.sh mode [auto|manual]" ;;
    esac
    ;;
  ensure) ensure ;;
  *)
    echo "Usage: hotkey.sh [toggle|menu] get | check | set \"<CHORD>\" | set-default | clear | mode [auto|manual]   or   hotkey.sh ensure" >&2
    exit 1
    ;;
esac
