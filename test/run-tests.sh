#!/usr/bin/env bash
# Offline tests: install into a temp CLAUDE_CONFIG_DIR, feed fake status line
# and hook JSON, check decisions, uninstall. Never touches your real config.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cfg"; unset USAGE_BRAKE_DIR
mkdir -p "$CLAUDE_CONFIG_DIR"
D="$CLAUDE_CONFIG_DIR/usage-brake"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

SID=11111111-aaaa-bbbb-cccc-000000000001
OTHER=22222222-aaaa-bbbb-cccc-000000000002
now=$(date +%s); reset7=$((now + 3*86400)); reset5=$((now + 7200))

# A user status line that should keep working, with options to preserve.
cat >"$T/mine.sh" <<'EOF'
#!/usr/bin/env bash
jq -r '"MINE " + .model.display_name'
EOF
chmod +x "$T/mine.sh"
printf '{"theme":"dark","statusLine":{"type":"command","command":"%s","padding":2},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}\n' "$T/mine.sh" >"$CLAUDE_CONFIG_DIR/settings.json"
cp "$CLAUDE_CONFIG_DIR/settings.json" "$T/orig-settings.json"

sl() { # sid pct7 [pct5] [reset7]
  local rl
  if [ "$2" = none ]; then rl='{}'; else rl="{\"seven_day\":{\"used_percentage\":$2,\"resets_at\":${4:-$reset7}}"; [ -n "${3:-}" ] && rl="$rl,\"five_hour\":{\"used_percentage\":$3,\"resets_at\":$reset5}"; rl="$rl}"; fi
  printf '{"session_id":"%s","model":{"display_name":"Fable 5.1"},"rate_limits":%s}' "$1" "$rl" | "$D/bin/statusline.sh"
}
hook() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' "$1" | "$D/bin/pretooluse.sh"; }
limit() { "$CLAUDE_CONFIG_DIR/skills/limit/limit.sh" "$@"; }

echo "install"
"$ROOT/install.sh" >/dev/null || bad "install exit code"
S="$CLAUDE_CONFIG_DIR/settings.json"
check "status line wrapped" '[ "$(jq -r .statusLine.command "$S")" = "$D/bin/statusline.sh" ]'
check "padding kept" '[ "$(jq -r .statusLine.padding "$S")" = 2 ]'
check "refreshInterval added" '[ "$(jq -r .statusLine.refreshInterval "$S")" = 60 ]'
check "other settings kept" '[ "$(jq -r .theme "$S")" = dark ] && [ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$S")" = "echo hi" ]'
check "one PreToolUse hook" '[ "$(jq ".hooks.PreToolUse | length" "$S")" = 1 ]'
check "backup made" 'ls "$CLAUDE_CONFIG_DIR"/settings.json.usage-brake-backup.* >/dev/null 2>&1'
"$ROOT/install.sh" >/dev/null
check "re-install is idempotent" '[ "$(jq ".hooks.PreToolUse | length" "$S")" = 1 ] && [ "$(cat "$D/orig-command")" = "$T/mine.sh" ]'

echo "no-op when not armed"
out=$(sl "$SID" 22 5)
check "original status line output passes through" '[ "$out" = "MINE Fable 5.1" ]' "got: $out"
check "usage file written" '[ "$(jq .seven_day.pct "$D/usage/$SID.json")" = 22 ]'
check "hook silent when nothing armed" '[ -z "$(hook "$SID")" ]'
st=$(limit "$SID")
check "status when off" 'grep -q "Usage brake: off" <<<"$st" && grep -q "weekly  22%" <<<"$st"' "$st"

echo "arm /limit 10"
st=$(limit "$SID" 10)
check "armed with baseline 22" 'grep -q "ARMED" <<<"$st" && grep -q "baseline 22%" <<<"$st"' "$st"
check "other session unaffected" '[ -z "$(hook "$OTHER")" ]'
check "allows under budget" '[ -z "$(hook "$SID")" ]'
out=$(sl "$SID" 25 5)
check "indicator line while armed" 'grep -q "brake 3/10 pts" <<<"$out"' "$out"
check "other session status line has no indicator" '! sl "$OTHER" 25 | grep -q brake'
sl "$SID" 31.9 >/dev/null
check "allows at 9.9 used" '[ -z "$(hook "$SID")" ]'
sl "$OTHER" 32 >/dev/null   # another session pushes plan usage over
r=$(hook "$SID")
check "denies at baseline+10 (via latest.json from another session)" '[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$r")" = deny ]' "$r"
check "deny reason" 'jq -r .hookSpecificOutput.permissionDecisionReason <<<"$r" | grep -q "Usage limit reached (22% → 32% weekly, budget 10 points). Write up where you are and stop."' "$r"
st=$(limit "$SID")
check "status shows tripped" 'grep -q TRIPPED <<<"$st"' "$st"
limit "$SID" off >/dev/null
check "off disarms" '[ -z "$(hook "$SID")" ] && [ ! -f "$D/budget/$SID.json" ]'

echo "ceiling"
limit "$SID" --max 33 >/dev/null
check "ceiling allows below" '[ -z "$(hook "$SID")" ]'
sl "$SID" 33 >/dev/null
check "ceiling denies at max" 'hook "$SID" | grep -q "ceiling reached"'
limit "$SID" off >/dev/null

echo "fail safe"
limit "$SID" 50 >/dev/null
check "fresh -> allow" '[ -z "$(hook "$SID")" ]'
for f in "$D/usage/$SID.json" "$D/usage/latest.json"; do jq '.ts -= 1000' "$f" >"$f.t" && mv "$f.t" "$f"; done
check "stale (>15 min) -> deny" 'hook "$SID" | grep -q "old, so it can"'
rm -f "$D/usage/"*.json
check "missing -> deny" 'hook "$SID" | grep -q "no usage reading"'
echo garbage >"$D/budget/$SID.json"
check "corrupt budget -> deny" 'hook "$SID" | grep -q deny'
limit "$SID" off >/dev/null

echo "pending baseline and windows"
limit "$SID" 5 >/dev/null
check "arming with no data -> pending" 'limit "$SID" | grep -q pending'
sl "$SID" 40 >/dev/null
hook "$SID" >/dev/null
check "first reading becomes baseline" '[ "$(jq .baseline "$D/budget/$SID.json")" = 40 ]'
sl "$SID" 43 >/dev/null; hook "$SID" >/dev/null
sl "$SID" 1 "" $((reset7 + 7*86400)) >/dev/null
check "weekly reset carries used points (3 + 1 = 4 < 5)" '[ -z "$(hook "$SID")" ] && [ "$(jq .carried "$D/budget/$SID.json")" = 3 ]'
sl "$SID" 2 "" $((reset7 + 7*86400)) >/dev/null
check "after reset, denies at 3 + 2 = 5" 'hook "$SID" | grep -q deny'
limit "$SID" off >/dev/null

echo "merging readings across sessions"
rm -f "$D/usage/"*.json
sl "$SID" 50 >/dev/null
limit "$SID" 5 >/dev/null
sl "$OTHER" 55 >/dev/null     # an active session sees the plan at 55%
sl "$SID" 50 >/dev/null       # this idle session re-renders its cached 50%
check "idle session's older lower reading does not mask a higher one" 'hook "$SID" | grep -q "50% → 55%"'
check "latest.json keeps the max" '[ "$(jq .seven_day.pct "$D/usage/latest.json")" = 55 ]'
jq --argjson p $((now - 10)) '.seven_day.resets_at = $p' "$D/usage/latest.json" >"$T/l" && mv "$T/l" "$D/usage/latest.json"
sl "$SID" 3 "" $((now + 7*86400)) >/dev/null
check "a window past its reset is dropped from latest.json" '[ "$(jq .seven_day.pct "$D/usage/latest.json")" = 3 ]'
limit "$SID" off >/dev/null
rm -f "$D/usage/"*.json
sl "$SID" none >/dev/null
printf '{"session_id":"%s","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$SID" "$reset5" | "$D/bin/statusline.sh" >/dev/null
limit "$SID" 2 >/dev/null
check "no weekly window -> falls back to 5-hour" '[ "$(jq -r .window "$D/budget/$SID.json")" = five_hour ]'
limit "$SID" off >/dev/null
limit "$SID" 10 --5h >/dev/null
check "--5h selects 5-hour" '[ "$(jq -r .window "$D/budget/$SID.json")" = five_hour ]'
limit "$SID" off >/dev/null

echo "argument handling"
check "bad arg -> usage" 'limit "$SID" banana | grep -q Usage'
check "zero budget refused" 'limit "$SID" 0 | grep -q "more than 0"'
check "bad session id refused" 'limit "../x" 5 | grep -q "no session id"'
check "limit.sh always exits 0" 'limit "../x" >/dev/null; [ $? = 0 ]'

echo "speed (no-op fast path, 200 calls)"
rm -f "$D/budget/"*.json
start=$(date +%s)
for _ in $(seq 200); do hook "$SID" >/dev/null; done
el=$(( $(date +%s) - start ))
check "200 unarmed hook calls in <= 3s (took ${el}s)" '[ $el -le 3 ]'

echo "uninstall"
"$ROOT/install.sh" --uninstall >/dev/null
check "settings restored exactly" 'diff <(jq -S . "$T/orig-settings.json") <(jq -S . "$S") >/dev/null' "$(diff <(jq -S . "$T/orig-settings.json") <(jq -S . "$S"))"
check "files removed" '[ ! -e "$D" ] && [ ! -e "$CLAUDE_CONFIG_DIR/skills/limit" ]'

echo "install with no prior status line / no settings.json"
rm -f "$S"
"$ROOT/install.sh" >/dev/null
out=$(sl "$SID" 22)
check "works without original status line" '[ -z "$out" ]' "$out"
"$ROOT/install.sh" --uninstall >/dev/null
check "uninstall leaves no statusLine or hooks" '[ "$(jq -c "{statusLine,hooks}" "$S")" = "{\"statusLine\":null,\"hooks\":null}" ]' "$(cat "$S")"

echo
echo "$pass passed, $fail failed"
[ $fail = 0 ]
