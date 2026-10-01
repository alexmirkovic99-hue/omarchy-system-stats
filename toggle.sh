#!/bin/bash
# Show or hide the System stats widget on the Omarchy bar.
#   toggle.sh toggle | show | hide | delete | status
#
#   hide    the stats disappear and a small button stays where they were;
#           clicking it (or `show`) brings them back. Sets `collapsed: true`
#           in the widget's shell.json entry through `omarchy bar set`.
#   show    expand the stats (puts the widget back if it was deleted)
#   toggle  hide when the stats are showing, otherwise show (the hotkey)
#   delete  take the widget off the bar completely (`omarchy plugin disable`);
#           its options and position are saved first and come back with `show`
#   status  prints "on" (stats showing), "collapsed" (small button) or "off"
#
# Files: reads and writes ~/.config/omarchy/shell.json (through the omarchy
# CLI, except one atomic write when a deleted widget is put back) and keeps
# one snapshot at ${XDG_STATE_HOME:-~/.local/state}/<plugin-id>/bar-entry.json.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
command -v jq >/dev/null 2>&1 || { echo "toggle.sh: jq is required" >&2; exit 1; }
ID=$(jq -r '.id // empty' "$HERE/manifest.json" 2>/dev/null || true)
[[ $ID =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "toggle.sh: cannot read the plugin id" >&2; exit 1; }

SHELL_JSON=${OMARCHY_SHELL_JSON:-$HOME/.config/omarchy/shell.json}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/$ID
SNAPSHOT=$STATE_DIR/bar-entry.json

# Two presses of the hotkey in quick succession must not interleave.
RUNTIME=${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}
mkdir -p "$RUNTIME"
exec 9>"$RUNTIME/$ID.toggle.lock"
flock -w 15 9 || { echo "toggle.sh: busy" >&2; exit 1; }

TMP_FILES=()
cleanup() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then rm -f -- "${TMP_FILES[@]}"; fi
}
trap cleanup EXIT

entry_of() { # prints this widget's bar entry (JSON) or nothing
  jq -c --arg id "$ID" 'first(.bar.layout[]?[]? | select(.id == $id)) // empty' "$SHELL_JSON" 2>/dev/null || true
}

on_bar() { [[ -n $(entry_of) ]]; }

is_collapsed() { [[ $(entry_of | jq -r '.collapsed // false' 2>/dev/null) == true ]]; }

# Where the widget sits: {"section": "left", "after": "<id before it>" | ""}.
placement() {
  jq -c --arg id "$ID" '
    first(.bar.layout // {} | to_entries[]
      | .key as $s | (.value // []) as $list
      | ($list | map(.id) | index($id)) as $i
      | select($i != null)
      | {section: $s, after: (if $i > 0 then ($list[$i - 1].id // "") else "" end)}) // empty' "$SHELL_JSON" 2>/dev/null || true
}

remove() {
  local current where old merged tmp attempt
  current=$(entry_of)
  [[ -n $current ]] || return 0
  where=$(placement)
  [[ -n $where ]] || where='{}'
  mkdir -p "$STATE_DIR"
  # Merge over an earlier snapshot, so an option saved before is never lost
  # even if the current entry lacks it (e.g. after an incomplete restore).
  # An unreadable snapshot is ignored rather than aborting the removal.
  old=$(jq -c '.entry // {} | if type == "object" then . else {} end' "$SNAPSHOT" 2>/dev/null || true)
  [[ -n $old ]] || old='{}'
  merged=$(jq -cn --argjson cur "$current" --argjson where "$where" --argjson prev "$old" '
    {entry: ($prev * $cur), section: ($where.section // null), after: ($where.after // null)}')
  tmp=$(mktemp "$STATE_DIR/.bar-entry.XXXXXX")
  TMP_FILES+=("$tmp")
  printf '%s\n' "$merged" >"$tmp"
  mv -f -- "$tmp" "$SNAPSHOT"
  # The shell can be busy reloading; retry until the widget is really gone.
  for attempt in 1 2 3; do
    omarchy plugin disable "$ID" >/dev/null 2>&1 || true
    sleep 0.5
    on_bar || return 0
  done
  echo "toggle.sh: could not remove the widget" >&2
  return 1
}

# Inserts a bar entry (JSON) into a section in one atomic write, together with
# its saved settings, then tells the shell to reload. Putting the widget on
# the bar first and restoring its settings afterwards would show it with
# default options for a moment (a flash of the wrong colours); this does not.
# Mirrors what the omarchy CLI does (omarchy-shell-config: jq -S, temp file,
# mv, reloadConfig). A symlinked shell.json is written at its target.
insert_entry() { # section after-id-or-empty entry-json
  local real tmp
  real=$(readlink -f -- "$SHELL_JSON" 2>/dev/null) || return 1
  [[ -s $real ]] || return 1
  tmp=$(mktemp "$real.XXXXXX")
  TMP_FILES+=("$tmp")
  jq -S -e --arg s "$1" --arg anchor "$2" --argjson entry "$3" '
      def arr: if type == "array" then . else [] end;
      (if type == "object" then . else {} end)
      | .version = 1
      | .bar = (.bar | if type == "object" then . else {} end)
      | .bar.layout = (.bar.layout | if type == "object" then . else {} end)
      | .bar.layout[$s] = (
          (.bar.layout[$s] | arr) as $list
          | (if $anchor == "" then null else ($list | map(.id) | index($anchor)) end) as $i
          | if $anchor == "" then [$entry] + $list
            elif $i == null then $list + [$entry]
            else $list[: $i + 1] + [$entry] + $list[$i + 1 :] end)
    ' "$real" >"$tmp" || return 1
  chmod --reference="$real" -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$real"
  omarchy-shell shell reloadConfig >/dev/null 2>&1 || omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
}

is_bar_widget() {
  omarchy plugin list --json 2>/dev/null |
    jq -e --arg id "$ID" 'any(.[]; .id == $id and ((.kinds // []) | index("bar-widget")))' >/dev/null 2>&1
}

saved_entry() { # the snapshot's options without "collapsed" (showing means expanded)
  jq -c --arg id "$ID" '(.entry // {}) | if type == "object" then . else {} end | del(.collapsed) + {id: $id}' "$SNAPSHOT" 2>/dev/null || true
}

# True when every saved option is on the bar entry with the same value.
restored() {
  local saved current
  saved=$(saved_entry)
  current=$(entry_of)
  [[ -n $saved && -n $current ]] || return 1
  jq -e -n --argjson s "$saved" --argjson e "$current" '$s | to_entries | all(.[]; $e[.key] == .value)' >/dev/null 2>&1
}

add() {
  on_bar && return 0
  local section="" after="" entry put attempt key value
  if [[ -s $SNAPSHOT ]]; then
    section=$(jq -r '.section // empty' "$SNAPSHOT" 2>/dev/null || true)
    after=$(jq -r '.after // empty' "$SNAPSHOT" 2>/dev/null || true)
    [[ $section =~ ^(left|center|right)$ ]] || section=""
    [[ $after =~ ^[A-Za-z0-9._:-]*$ ]] || after=""
  fi
  # Normal path: put the entry back with its saved options, in one write,
  # where it was before.
  if [[ -n $section ]] && is_bar_widget; then
    entry=$(saved_entry)
    if [[ -n $entry ]] && insert_entry "$section" "$after" "$entry"; then
      sleep 0.5
      on_bar && return 0
    fi
  fi
  # Fallback: let omarchy place it (where it was if known, else the widget's
  # default section), then put the saved options back one by one.
  local where=()
  if [[ -n $section && -n $after ]]; then
    where=(--section "$section" --after "$after")
  elif [[ -n $section ]]; then
    where=(--section "$section" --index 0)
  fi
  for put in 1 2 3; do
    omarchy bar put "$ID" "${where[@]}" >/dev/null 2>&1 || true
    sleep 0.5
    on_bar && break
  done
  on_bar || { echo "toggle.sh: could not add the widget" >&2; return 1; }
  [[ -s $SNAPSHOT ]] || return 0
  for attempt in 1 2 3 4; do
    sleep 0.5
    saved_entry | jq -r 'to_entries[] | select(.key != "id") | [.key, (.value | tojson)] | @tsv' |
      while IFS=$'\t' read -r key value; do
        omarchy bar set "$ID" "$key" "$value" --json >/dev/null 2>&1 || true
      done
    sleep 0.5
    restored && return 0
  done
  echo "toggle.sh: could not restore the saved options" >&2
  return 1
}

set_collapsed() { # true|false
  local attempt
  for attempt in 1 2 3; do
    omarchy bar set "$ID" collapsed "$1" --json >/dev/null 2>&1 || true
    sleep 0.4
    if [[ $1 == true ]]; then is_collapsed && return 0; else is_collapsed || return 0; fi
  done
  echo "toggle.sh: could not change the widget" >&2
  return 1
}

hide() {
  on_bar || return 0
  is_collapsed && return 0
  set_collapsed true
}

show() {
  if on_bar; then
    is_collapsed || return 0
    set_collapsed false
  else
    add
  fi
}

status() {
  if ! on_bar; then echo off; elif is_collapsed; then echo collapsed; else echo on; fi
}

case "${1:-}" in
  toggle) if on_bar && ! is_collapsed; then hide; else show; fi ;;
  show) show ;;
  hide) hide ;;
  delete) remove ;;
  status) status ;;
  *)
    echo "Usage: toggle.sh toggle|show|hide|delete|status" >&2
    exit 1
    ;;
esac
