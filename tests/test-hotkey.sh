#!/bin/bash
# Tests hotkey.sh against a temporary bindings file and a fake hyprctl.
# Never touches ~/.config/hypr. Run: tests/test-hotkey.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HK=$ROOT/hotkey.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ID=$(jq -r .id "$ROOT/manifest.json")
BEGIN_RE=">>> $ID hotkey ("
BEGIN_MENU_RE=">>> $ID hotkey-menu ("

mkdir -p "$T/bin" "$T/hypr" "$T/run"
cat >"$T/bin/hyprctl" <<'FAKE'
#!/bin/bash
[[ -f $FAKE_DOWN ]] && exit 1
case "$1" in
  binds) cat "$FAKE_BINDS" ;;
  reload)
    # Simulate Hyprland rejecting a chord whose key is "Q".
    if grep -q '"CTRL + ALT + Q"' "$BINDINGS_FILE"; then echo "bindings.lua:99: bad bind" >"$FAKE_ERR"; else rm -f "$FAKE_ERR"; fi ;;
  configerrors) [[ -f $FAKE_ERR ]] && cat "$FAKE_ERR" ;;
esac
exit 0
FAKE
chmod +x "$T/bin/hyprctl"

export BINDINGS_FILE=$T/hypr/bindings.lua HYPRCTL=$T/bin/hyprctl XDG_RUNTIME_DIR=$T/run
export FAKE_BINDS=$T/binds.json FAKE_ERR=$T/err FAKE_DOWN=$T/down
export XDG_STATE_HOME=$T/state NOTIFY_CMD=$T/bin/notify FAKE_NOTIFY_LOG=$T/notify.log
cat >"$T/bin/notify" <<'FAKE'
#!/bin/bash
echo "$*" >>"$FAKE_NOTIFY_LOG"
FAKE
chmod +x "$T/bin/notify"
printf -- '-- user bindings\no.bind("SUPER + B", "Browser", "x")\n\n' >"$BINDINGS_FILE"
cp "$BINDINGS_FILE" "$T/original.lua"
echo '[]' >"$FAKE_BINDS"

pass=0 fail=0
check() { # description, expected, actual
  if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "FAIL: $1"$'\n'"  expected: $2"$'\n'"  actual:   $3"
  fi
}
bind() { printf '{"modmask":%s,"key":"%s","description":"%s","dispatcher":"__lua"}' "$1" "$2" "$3"; }
hk() { "$HK" "$@" 2>&1; }
blocks() { grep -c "$BEGIN_RE" "$BINDINGS_FILE"; }
same() { cmp -s "$1" "$2" && echo same || echo different; }

# 1. nothing is written on its own: get/check on a fresh file change nothing
check "no hotkey by default" "" "$(hk get)"
check "check is silent without a hotkey" "" "$(hk check)"
check "file untouched by get/check" "same" "$(same "$BINDINGS_FILE" "$T/original.lua")"

# 2. set writes one marked block with a description; user content kept
check "set prints the chord" "SUPER + CTRL + J" "$(hk set "SUPER + CTRL + J")"
check "get reads it back" "SUPER + CTRL + J" "$(hk get)"
check "one block" "1" "$(blocks)"
grep -q '"Expand or collapse System stats"' "$BINDINGS_FILE"; check "has a description (SUPER+K menu)" "0" "$?"
grep -q "'$ROOT/toggle.sh' toggle" "$BINDINGS_FILE"; check "runs this plugin's toggle.sh" "0" "$?"
grep -q 'o.bind("SUPER + B", "Browser", "x")' "$BINDINGS_FILE"; check "user binding kept" "0" "$?"
check "no backup or temp files next to bindings.lua" "1" "$(find "$T/hypr" -type f | wc -l)"

# 3. setting the same chord again is fine (own binding is not a conflict)
echo "[$(bind 68 J 'Expand or collapse System stats')]" >"$FAKE_BINDS"
check "re-set own chord" "SUPER + CTRL + J" "$(hk set "SUPER + CTRL + J")"
check "still one block" "1" "$(blocks)"

# 4. clear restores the original file exactly (including its trailing blank line)
hk clear >/dev/null
check "cleared" "" "$(hk get)"
check "identical to original after set+clear" "same" "$(same "$BINDINGS_FILE" "$T/original.lua")"
before=$(stat -c '%i %Y' "$BINDINGS_FILE")
hk clear >/dev/null
check "clear without a block does not rewrite the file" "$before" "$(stat -c '%i %Y' "$BINDINGS_FILE")"

# 5. conflicts are refused and name the owner
echo "[$(bind 64 W 'Close window')]" >"$FAKE_BINDS"
out=$(hk set "SUPER + W"); check "conflict exit code" "3" "$?"
[[ $out == *"Close window"* ]]; check "conflict names the owner" "0" "$?"
# a binding with our description on ANOTHER chord (e.g. a second copy of this plugin) still counts
echo "[$(bind 68 K 'Expand or collapse System stats')]" >"$FAKE_BINDS"
hk set "SUPER + CTRL + K" >/dev/null; check "same description elsewhere is a conflict" "3" "$?"

# 6. bindings made by key code (Hyprland reports key "") block digits/symbols
echo "[$(bind 64 '' 'Switch to workspace 1')]" >"$FAKE_BINDS"
out=$(hk set "SUPER + 1"); check "key-code binding blocks SUPER + 1" "3" "$?"
[[ $out == *"bound by key code"* ]]; check "key-code conflict explained" "0" "$?"
check "letters are not blocked by key-code bindings" "SUPER + Z" "$(hk set "SUPER + Z")"
hk clear >/dev/null

# 7. fail closed when Hyprland's bindings cannot be read
echo '[]' >"$FAKE_BINDS"; touch "$FAKE_DOWN"; cp "$BINDINGS_FILE" "$T/pre.lua"
hk set "SUPER + CTRL + J" >/dev/null; check "hyprctl failing: refused" "9" "$?"
hk set-default >/dev/null; check "hyprctl failing: set-default refused" "9" "$?"
rm -f "$FAKE_DOWN"
echo 'not json' >"$FAKE_BINDS"
hk set "SUPER + CTRL + J" >/dev/null; check "garbage from hyprctl: refused" "9" "$?"
HYPRCTL=$T/bin/does-not-exist hk set "SUPER + CTRL + J" >/dev/null; check "no hyprctl: refused" "9" "$?"
check "nothing written while it could not check" "same" "$(same "$BINDINGS_FILE" "$T/pre.lua")"
echo '[]' >"$FAKE_BINDS"

# 8. validation (injection, duplicates, missing modifier)
hk set "M" >/dev/null; check "no modifier rejected" "2" "$?"
hk set 'CTRL + M"); os.execute("x' >/dev/null; check "Lua injection rejected" "2" "$?"
hk set 'CTRL + M\" ..' >/dev/null; check "quote rejected" "2" "$?"
hk set "SUPER + SUPER + M" >/dev/null; check "duplicate modifier rejected" "2" "$?"
hk set "CTRL + m" >/dev/null; check "lower-case key rejected" "2" "$?"
check "nothing written by rejected input" "same" "$(same "$BINDINGS_FILE" "$T/pre.lua")"

# 9. Hyprland rejecting the change: rolled back to the exact previous file
hk set "CTRL + ALT + Q" >/dev/null; check "rejected by Hyprland" "4" "$?"
check "rolled back exactly" "same" "$(same "$BINDINGS_FILE" "$T/pre.lua")"

# 10. set-default: first free default; skips taken ones; none free = 5
check "set-default takes the first" "SUPER + CTRL + M" "$(hk set-default)"
hk clear >/dev/null
echo "[$(bind 68 M 'Taken 1'), $(bind 72 M 'Taken 2')]" >"$FAKE_BINDS"
check "set-default skips taken" "CTRL + ALT + M" "$(hk set-default)"
hk clear >/dev/null
echo "[$(bind 68 M a), $(bind 72 M b), $(bind 12 M c), $(bind 69 M d)]" >"$FAKE_BINDS"
hk set-default >/dev/null; check "none free" "5" "$?"
check "nothing bound when none free" "" "$(hk get)"
echo '[]' >"$FAKE_BINDS"

# 11. check warns when another binding later takes our chord (read-only)
hk set "SUPER + CTRL + J" >/dev/null
cp "$BINDINGS_FILE" "$T/pre.lua"
echo "[$(bind 68 J 'Expand or collapse System stats'), $(bind 68 J 'New Omarchy thing')]" >"$FAKE_BINDS"
check "check names the new owner" "SUPER + CTRL + J is also used by: New Omarchy thing" "$(hk check)"
check "check does not write" "same" "$(same "$BINDINGS_FILE" "$T/pre.lua")"
echo '[]' >"$FAKE_BINDS"; hk clear >/dev/null

# 12. a damaged block (END marker deleted by hand) is never "repaired" by guessing
printf -- '-- mine\n-- >>> %s hotkey (managed by the System stats plugin; change or clear it from its panel) >>>\no.bind("SUPER + CTRL + J", "Expand or collapse System stats", "x")\no.bind("SUPER + G", "Git", "lazygit")\n' "$ID" >"$BINDINGS_FILE"
cp "$BINDINGS_FILE" "$T/damaged.lua"
hk clear >/dev/null; check "clear refuses a damaged block" "8" "$?"
hk set "SUPER + CTRL + L" >/dev/null; check "set refuses a damaged block" "8" "$?"
check "user binding after the damaged block survives" "same" "$(same "$BINDINGS_FILE" "$T/damaged.lua")"

# 13. another plugin's marked block is left alone
printf -- '-- mine\n\n-- >>> other.plugin hotkey (x) >>>\no.bind("SUPER + ALT + W", "Other", "y")\n-- <<< other.plugin hotkey <<<\n' >"$BINDINGS_FILE"
cp "$BINDINGS_FILE" "$T/other.lua"
hk set "SUPER + CTRL + J" >/dev/null
grep -q 'o.bind("SUPER + ALT + W", "Other", "y")' "$BINDINGS_FILE"; check "other block kept" "0" "$?"
hk clear >/dev/null
check "other block file identical after clear" "same" "$(same "$BINDINGS_FILE" "$T/other.lua")"

# 14. missing bindings.lua: refused, not created
BINDINGS_FILE=$T/hypr/none.lua hk set "SUPER + CTRL + J" >/dev/null; check "missing file: exit 7" "7" "$?"
[[ -e $T/hypr/none.lua ]]; check "missing file not created" "1" "$?"
check "clear on missing file is a no-op" "0" "$(BINDINGS_FILE=$T/hypr/none.lua "$HK" clear >/dev/null 2>&1; echo $?)"

# 15. symlinked bindings.lua (dotfiles) keeps the link; permissions kept
mkdir -p "$T/dotfiles"; printf -- '-- dotfiles\n' >"$T/dotfiles/bindings.lua"; chmod 640 "$T/dotfiles/bindings.lua"
ln -s "$T/dotfiles/bindings.lua" "$T/hypr/link.lua"
BINDINGS_FILE=$T/hypr/link.lua hk set "SUPER + CTRL + J" >/dev/null
[[ -L $T/hypr/link.lua ]]; check "symlink kept" "0" "$?"
grep -q "$BEGIN_RE" "$T/dotfiles/bindings.lua"; check "target edited" "0" "$?"
check "permissions kept" "640" "$(stat -c %a "$T/dotfiles/bindings.lua")"

# 16. concurrent edits are serialised: exactly one block afterwards
printf -- '-- mine\n' >"$BINDINGS_FILE"
for c in "SUPER + CTRL + J" "SUPER + CTRL + K" "SUPER + CTRL + L" "SUPER + ALT + J"; do "$HK" set "$c" >/dev/null 2>&1 & done
wait
check "one block after parallel sets" "1" "$(blocks)"
check "no stray temp files" "0" "$(find "$T/hypr" -name 'bindings.lua.*' | wc -l)"
check "no stray backups in the runtime dir" "0" "$(find "$T/run" -name 'bindings.lua.backup*' | wc -l)"

# 17. a plugin folder whose path cannot be quoted safely is refused
mkdir -p "$T/bad dir'\"x"
cp "$ROOT/hotkey.sh" "$ROOT/hotkey.conf" "$ROOT/manifest.json" "$ROOT/toggle.sh" "$T/bad dir'\"x/"
printf -- '-- mine\n' >"$BINDINGS_FILE"; cp "$BINDINGS_FILE" "$T/pre.lua"
"$T/bad dir'\"x/hotkey.sh" set "SUPER + CTRL + J" >/dev/null 2>&1; check "unsafe plugin path refused" "6" "$?"
check "nothing written for unsafe path" "same" "$(same "$BINDINGS_FILE" "$T/pre.lua")"

# 18. AUTO / MANUAL ----------------------------------------------------------
reset() { rm -rf "$XDG_STATE_HOME"; : >"$FAKE_NOTIFY_LOG"; echo '[]' >"$FAKE_BINDS"; rm -f "$FAKE_DOWN" "$FAKE_ERR"; printf -- '-- user bindings\no.bind("SUPER + B", "Browser", "x")\n\n' >"$BINDINGS_FILE"; cp "$BINDINGS_FILE" "$T/original.lua"; }
chord_state() { jq -r ".toggle.$1 // empty | tostring" "$XDG_STATE_HOME/$ID/hotkey.json" 2>/dev/null; }
menu_state() { jq -r ".menu.$1 // empty | tostring" "$XDG_STATE_HOME/$ID/hotkey.json" 2>/dev/null; }
menu_blocks() { grep -c "$BEGIN_MENU_RE" "$BINDINGS_FILE"; }

reset
check "MANUAL is the default mode" "manual" "$(hk mode)"
check "ensure does nothing in MANUAL" "" "$(hk ensure)"
check "MANUAL ensure wrote nothing" "same" "$(same "$BINDINGS_FILE" "$T/original.lua")"
check "no state file before any choice" "0" "$(find "$XDG_STATE_HOME" -type f 2>/dev/null | wc -l)"
check "Add (set-default) works in MANUAL" "SUPER + CTRL + M" "$(hk set-default)"
check "Add records origin=default" "default" "$(chord_state origin)"
check "MANUAL stays MANUAL after Add" "manual" "$(hk mode)"

# switching to AUTO adds a default straight away (that is the request)
reset
check "mode auto adds a default" "SUPER + CTRL + M
auto" "$(hk mode auto)"
check "mode is auto" "auto" "$(hk mode)"
check "AUTO origin=default" "default" "$(chord_state origin)"
check "announced once" "1" "$(wc -l <"$FAKE_NOTIFY_LOG")"
check "ensure again changes nothing" "" "$(hk ensure)"
check "still one block" "1" "$(blocks)"
check "no second notification" "1" "$(wc -l <"$FAKE_NOTIFY_LOG")"

# AUTO skips defaults that are taken
reset
echo "[$(bind 68 M 'Taken 1'), $(bind 72 M 'Taken 2')]" >"$FAKE_BINDS"
check "AUTO skips taken defaults" "CTRL + ALT + M
auto" "$(hk mode auto)"

# a default that another binding takes later is moved (AUTO only)
reset; hk mode auto >/dev/null
echo "[$(bind 68 M 'Some new binding')]" >"$FAKE_BINDS"
check "AUTO moves a taken default" "SUPER + ALT + M" "$(hk ensure)"
check "block holds the new chord" "SUPER + ALT + M" "$(hk get)"
check "still one block after the move" "1" "$(blocks)"
reset; hk mode auto >/dev/null; hk mode manual >/dev/null
echo "[$(bind 68 M 'Some new binding')]" >"$FAKE_BINDS"
check "MANUAL never moves it" "" "$(hk ensure)"
check "chord unchanged in MANUAL" "SUPER + CTRL + M" "$(hk get)"
check "switching to MANUAL keeps the hotkey" "manual" "$(hk mode)"

# a chord the user chose is never touched, even in AUTO
reset; hk mode auto >/dev/null
echo '[]' >"$FAKE_BINDS"; hk set "CTRL + ALT + K" >/dev/null
check "origin=user after Custom" "user" "$(chord_state origin)"
echo "[$(bind 12 K 'Taken later')]" >"$FAKE_BINDS"
check "AUTO leaves the user's chord" "" "$(hk ensure)"
check "user chord unchanged" "CTRL + ALT + K" "$(hk get)"

# Clear sticks in AUTO until the user asks again
reset; hk mode auto >/dev/null; echo '[]' >"$FAKE_BINDS"
hk clear >/dev/null
check "cleared in AUTO" "" "$(hk get)"
check "AUTO ensure does not bring it back after Clear" "" "$(hk ensure)"
check "file restored after Clear" "same" "$(same "$BINDINGS_FILE" "$T/original.lua")"
check "Add after Clear works" "SUPER + CTRL + M" "$(hk set-default)"
hk clear >/dev/null
check "switching to AUTO again re-adds" "SUPER + CTRL + M
auto" "$(hk mode auto)"

# none free: AUTO reports it and writes nothing; a lost default with no replacement is removed
reset
echo "[$(bind 68 M a), $(bind 72 M b), $(bind 12 M c), $(bind 69 M d)]" >"$FAKE_BINDS"
out=$(hk mode auto); check "AUTO with no free default" "5" "$?"
[[ $out == *"none of the default shortcuts is free"* ]]; check "says why" "0" "$?"
check "mode stays auto so a freed shortcut is picked up later" "auto" "$(hk mode)"
check "nothing bound" "" "$(hk get)"
reset; hk mode auto >/dev/null
echo "[$(bind 68 M a), $(bind 72 M b), $(bind 12 M c), $(bind 69 M d)]" >"$FAKE_BINDS"
hk ensure >/dev/null; check "default lost with no replacement" "5" "$?"
check "conflicting default removed" "" "$(hk get)"
check "and it stays removed" "" "$(hk ensure)"

# AUTO fails closed when conflicts cannot be checked
reset; touch "$FAKE_DOWN"
hk mode auto >/dev/null; check "AUTO refuses when Hyprland is unreachable" "9" "$?"
check "nothing written when unreachable" "same" "$(same "$BINDINGS_FILE" "$T/original.lua")"
rm -f "$FAKE_DOWN"

# bad arguments / corrupt state
check "mode with a bad argument" "1" "$(hk mode sometimes >/dev/null; echo $?)"
reset; mkdir -p "$XDG_STATE_HOME/$ID"; echo 'not json' >"$XDG_STATE_HOME/$ID/hotkey.json"
check "corrupt state falls back to MANUAL" "manual" "$(hk mode)"
check "corrupt state is replaced on the next change" "SUPER + CTRL + M" "$(hk set-default)"
check "state valid again" "default" "$(chord_state origin)"
check "state is the only file written outside bindings.lua" "1" "$(find "$XDG_STATE_HOME" -type f | wc -l)"

# 19. the second hotkey: open the widget's menu --------------------------------
reset
check "menu hotkey: nothing by default" "" "$(hk menu get)"
check "menu mode defaults to MANUAL" "manual" "$(hk menu mode)"
check "menu set" "CTRL + ALT + U" "$(hk menu set "CTRL + ALT + U")"
check "menu get" "CTRL + ALT + U" "$(hk menu get)"
check "toggle unaffected by menu" "" "$(hk get)"
check "one menu block" "1" "$(menu_blocks)"
check "no toggle block" "0" "$(blocks)"
grep -q '"Open System stats menu"' "$BINDINGS_FILE"; check "menu has its own description" "0" "$?"
grep -q "omarchy-shell shell toggle '$ID' '{}'" "$BINDINGS_FILE"; check "menu runs the shell toggle for this plugin" "0" "$?"
check "menu origin=user" "user" "$(menu_state origin)"

# both hotkeys live side by side and are independent
check "toggle set alongside" "CTRL + ALT + M" "$(hk set "CTRL + ALT + M")"
check "both blocks present" "1 1" "$(blocks) $(menu_blocks)"
check "menu chord kept" "CTRL + ALT + U" "$(hk menu get)"
check "toggle chord kept" "CTRL + ALT + M" "$(hk get)"

# the two cannot be given the same chord (the other one's binding is a conflict)
echo "[$(bind 12 M 'Expand or collapse System stats'), $(bind 12 U 'Open System stats menu')]" >"$FAKE_BINDS"
out=$(hk menu set "CTRL + ALT + M"); check "menu cannot take toggle's chord" "3" "$?"
[[ $out == *"Expand or collapse System stats"* ]]; check "names the other hotkey" "0" "$?"
out=$(hk set "CTRL + ALT + U"); check "toggle cannot take menu's chord" "3" "$?"
echo '[]' >"$FAKE_BINDS"

# clearing one leaves the other; clearing both restores the original file
hk menu clear >/dev/null
check "menu cleared" "" "$(hk menu get)"
check "toggle still there" "CTRL + ALT + M" "$(hk get)"
check "only the toggle block remains" "1 0" "$(blocks) $(menu_blocks)"
hk clear >/dev/null
check "both cleared: original file back" "same" "$(same "$BINDINGS_FILE" "$T/original.lua")"

# independent modes and defaults; ensure looks after both
reset
check "menu AUTO adds the menu default" "SUPER + CTRL + U
auto" "$(hk menu mode auto)"
check "toggle is still MANUAL" "manual" "$(hk mode)"
check "no toggle hotkey was added" "" "$(hk get)"
check "ensure with nothing to do" "" "$(hk ensure)"
hk mode auto >/dev/null
echo "[$(bind 68 M 'Taken'), $(bind 68 U 'Also taken')]" >"$FAKE_BINDS"
out=$(hk ensure); check "ensure moves both taken defaults" "SUPER + ALT + M
SUPER + ALT + U" "$out"
check "toggle moved" "SUPER + ALT + M" "$(hk get)"
check "menu moved" "SUPER + ALT + U" "$(hk menu get)"
check "both blocks, no duplicates" "1 1" "$(blocks) $(menu_blocks)"
echo '[]' >"$FAKE_BINDS"
hk menu set "CTRL + ALT + K" >/dev/null
echo "[$(bind 12 K 'Taken later')]" >"$FAKE_BINDS"
check "menu user chord untouched by ensure" "" "$(hk ensure)"
check "menu chord unchanged" "CTRL + ALT + K" "$(hk menu get)"

# a damaged menu block does not block the toggle block, but is never guessed at
reset; hk menu set "CTRL + ALT + U" >/dev/null
sed -i '/<<< .* hotkey-menu <<</d' "$BINDINGS_FILE"
hk menu clear >/dev/null 2>&1; check "damaged menu block refused" "8" "$?"
check "other content kept" "1" "$(grep -c 'o.bind("SUPER + B"' "$BINDINGS_FILE")"

hk bogus >/dev/null; check "usage error for unknown command" "1" "$?"
hk menu bogus >/dev/null; check "usage error for unknown menu command" "1" "$?"

hk bogus >/dev/null; check "usage error" "1" "$?"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
