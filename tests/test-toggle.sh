#!/bin/bash
# Tests toggle.sh against a temporary shell.json with a fake `omarchy` CLI.
# Never touches ~/.config/omarchy. Run: tests/test-toggle.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TG=$ROOT/toggle.sh
ID=$(jq -r .id "$ROOT/manifest.json")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"

# Fake omarchy CLI: just enough of plugin list/disable and bar put/set.
cat >"$T/bin/omarchy" <<'FAKE'
#!/bin/bash
echo "omarchy $*" >>"$FAKE_LOG"
J=$OMARCHY_SHELL_JSON
case "$1 $2" in
  "plugin list")
    PL=${FAKE_PLUGINS-}
    [[ -n $PL ]] || PL="[{\"id\":\"$FAKE_ID\",\"kinds\":[\"bar-widget\"]}]"
    echo "$PL" ;;
  "plugin disable")
    jq --arg id "$3" '.bar.layout |= with_entries(.value |= map(select(.id != $id)))' "$J" >"$J.t" && cat "$J.t" >"$J" && rm "$J.t" ;;
  "bar put")
    id=$3; shift 3; section=right; after=""; index=""
    while [[ $# -gt 0 ]]; do case $1 in --section) section=$2; shift 2 ;; --after) after=$2; shift 2 ;; --index) index=$2; shift 2 ;; *) shift ;; esac; done
    jq --arg id "$id" --arg s "$section" --arg a "$after" --arg ix "$index" '
      (.bar.layout[$s] // []) as $l
      | (if $a != "" then (($l | map(.id) | index($a)) // ($l | length)) + 1 elif $ix != "" then ($ix | tonumber) else ($l | length) end) as $i
      | .bar.layout[$s] = ($l[:$i] + [{id: $id}] + $l[$i:])' "$J" >"$J.t" && cat "$J.t" >"$J" && rm "$J.t" ;;
  "bar set")
    jq --arg id "$3" --arg k "$4" --argjson v "$5" '.bar.layout |= with_entries(.value |= map(if .id == $id then .[$k] = $v else . end))' "$J" >"$J.t" && cat "$J.t" >"$J" && rm "$J.t" ;;
esac
FAKE
cat >"$T/bin/omarchy-shell" <<'FAKE'
#!/bin/bash
echo "omarchy-shell $*" >>"$FAKE_LOG"
FAKE
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_ID="$ID" XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run"
export OMARCHY_SHELL_JSON="$T/shell.json"
SNAP="$XDG_STATE_HOME/$ID/bar-entry.json"
fresh() { # $1 = section for the widget (default left, after workspaces)
  local s=${1:-left}
  jq -n --arg id "$ID" --arg s "$s" '
    {version: 1, plugins: [], bar: {layout: {left: [{id: "omarchy.menu"}, {id: "omarchy.workspaces"}], center: [{id: "omarchy.clock"}], right: [{id: "omarchy.tray"}]}}}
    | if $s == "left" then .bar.layout.left += [{id: $id, palette: "fixed:dracula", collapsed: true, showTemps: false}]
      else .bar.layout.right = [{id: $id, palette: "fixed:dracula", showTemps: false}] + .bar.layout.right end' >"$OMARCHY_SHELL_JSON"
  : >"$FAKE_LOG"
}
entry() { jq -c --arg id "$ID" 'first(.bar.layout[][] | select(.id == $id)) // null' "$OMARCHY_SHELL_JSON"; }
where() { jq -r --arg id "$ID" '.bar.layout | to_entries[] | .key as $s | (.value | map(.id) | index($id)) as $i | select($i != null) | "\($s) \($i)"' "$OMARCHY_SHELL_JSON"; }
st() { "$TG" status; }

pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"$'\n'"  expected: $2"$'\n'"  actual:   $3"; fi; }

# delete saves the whole entry and where it was, then disables
fresh
"$TG" delete
check "deleted" "off" "$(st)"
check "snapshot has palette" "fixed:dracula" "$(jq -r .entry.palette "$SNAP")"
check "snapshot keeps every option" "true" "$(jq '.entry.showTemps == false and .entry.collapsed == true' "$SNAP")"
check "snapshot remembers the place" "left omarchy.workspaces" "$(jq -r '"\(.section) \(.after)"' "$SNAP")"
grep -q "plugin disable $ID" "$FAKE_LOG"; check "disable called" "0" "$?"
[[ -d $XDG_STATE_HOME/omarchy ]]; check "no shared omarchy/* state used" "1" "$?"

# show (when deleted): one atomic write, no `bar put`, same place, expanded
: >"$FAKE_LOG"
"$TG" show
check "back on the bar" "on" "$(st)"
check "palette present on first appearance" "fixed:dracula" "$(entry | jq -r .palette)"
check "other options restored" "false" "$(entry | jq .showTemps)"
check "collapsed dropped so the stats show" "null" "$(entry | jq .collapsed)"
check "same place as before" "left 2" "$(where)"
grep -q "bar put" "$FAKE_LOG"; check "fast path does not use 'bar put'" "1" "$?"
grep -q "omarchy-shell shell reloadConfig" "$FAKE_LOG"; check "shell told to reload" "0" "$?"
check "no temp files left" "0" "$(find "$T" -maxdepth 1 -name 'shell.json.*' | wc -l)"
check "other entries untouched" "[\"omarchy.menu\",\"omarchy.workspaces\",\"$ID\"]" "$(jq -c '[.bar.layout.left[].id]' "$OMARCHY_SHELL_JSON")"

# toggle: hides into the small button, then shows the stats again
"$TG" toggle; check "toggle hides into the small button" "collapsed" "$(st)"
check "hidden = collapsed true" "true" "$(entry | jq .collapsed)"
check "palette kept while hidden" "fixed:dracula" "$(entry | jq -r .palette)"
check "position kept while hidden" "left 2" "$(where)"
"$TG" toggle; check "toggle shows the stats" "on" "$(st)"
check "palette survives the round trip" "fixed:dracula" "$(entry | jq -r .palette)"

# hide / show are idempotent, and hide never removes or re-places the widget
"$TG" hide; "$TG" hide; check "hide twice" "collapsed" "$(st)"
"$TG" show; "$TG" show; check "show twice" "on" "$(st)"
: >"$FAKE_LOG"; "$TG" hide
grep -q "plugin disable\|bar put" "$FAKE_LOG"; check "hide never removes the widget" "1" "$?"
"$TG" show

# hidden, then deleted, then shown: comes back expanded with its options
"$TG" hide; "$TG" delete
check "deleted while hidden" "off" "$(st)"
"$TG" toggle; check "toggle after delete adds it back" "on" "$(st)"
check "palette kept through hide+delete+show" "fixed:dracula" "$(entry | jq -r .palette)"
check "not collapsed after re-adding" "null" "$(entry | jq .collapsed)"

# hide when absent does nothing; show when absent adds
"$TG" delete; "$TG" hide; check "hide when absent does nothing" "off" "$(st)"
"$TG" show; check "show when absent adds it" "on" "$(st)"

# a second delete keeps options even though the first show dropped `collapsed`
"$TG" delete
check "snapshot still has palette after second delete" "fixed:dracula" "$(jq -r .entry.palette "$SNAP")"
"$TG" show

# a widget in the right section, first in it, comes back there
rm -rf "$XDG_STATE_HOME"; fresh right
"$TG" delete; "$TG" show
check "first in right section restored" "right 0" "$(where)"

# no snapshot: falls back to `omarchy bar put` with the widget's default place
rm -rf "$XDG_STATE_HOME"; fresh; "$TG" delete; rm -rf "$XDG_STATE_HOME"; : >"$FAKE_LOG"
"$TG" show
check "fallback adds the widget" "on" "$(st)"
grep -q "bar put $ID\$" "$FAKE_LOG"; check "fallback uses plain 'bar put'" "0" "$?"

# the plugin is not reported as a bar widget: fallback restores place and settings
rm -rf "$XDG_STATE_HOME"; fresh; "$TG" delete; : >"$FAKE_LOG"
FAKE_PLUGINS='[]' "$TG" show
check "fallback restores settings via 'bar set'" "fixed:dracula" "$(entry | jq -r .palette)"
grep -q "bar put $ID --section left --after omarchy.workspaces" "$FAKE_LOG"; check "fallback keeps the place" "0" "$?"
check "fallback place" "left 2" "$(where)"

# a corrupted snapshot never blocks a delete
printf 'not json' >"$SNAP"
"$TG" delete; check "delete despite corrupted snapshot" "off" "$(st)"
check "snapshot rewritten" "fixed:dracula" "$(jq -r .entry.palette "$SNAP")"
"$TG" show

# symlinked shell.json (dotfiles) stays a symlink; permissions kept
rm -rf "$XDG_STATE_HOME"; fresh; mkdir -p "$T/dot"; mv "$OMARCHY_SHELL_JSON" "$T/dot/shell.json"
chmod 640 "$T/dot/shell.json"; ln -s "$T/dot/shell.json" "$OMARCHY_SHELL_JSON"
"$TG" delete; "$TG" show
[[ -L $OMARCHY_SHELL_JSON ]]; check "shell.json symlink kept" "0" "$?"
check "shell.json permissions kept" "640" "$(stat -c %a "$T/dot/shell.json")"
check "on through the symlink" "on" "$(st)"
rm "$OMARCHY_SHELL_JSON"; mv "$T/dot/shell.json" "$OMARCHY_SHELL_JSON"

# two hotkey presses at once are serialised: hide then show, one entry
rm -rf "$XDG_STATE_HOME"; fresh; "$TG" show
"$TG" toggle & "$TG" toggle & wait
check "parallel toggles end shown" "on" "$(st)"
check "exactly one entry" "1" "$(jq --arg id "$ID" '[.bar.layout[][] | select(.id == $id)] | length' "$OMARCHY_SHELL_JSON")"

"$TG" bogus >/dev/null 2>&1; check "usage error" "1" "$?"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
