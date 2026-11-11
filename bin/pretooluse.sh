#!/usr/bin/env bash
# claude-usage-brake PreToolUse hook: refuses every tool call once this
# session's /limit budget is used up. Sessions without /limit pass straight
# through (no jq, no file reads beyond one glob).
D="${USAGE_BRAKE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-brake}"

# Fast path: nothing armed anywhere -> allow.
set -- "$D"/budget/*.json
[ -e "$1" ] || exit 0

input=$(cat)
IFS=$'\t' read -r sid tool < <(printf '%s' "$input" | jq -r '[.session_id // "", .tool_name // ""] | join("\t")' 2>/dev/null)
case "$sid" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
bf="$D/budget/$sid.json"
[ -f "$bf" ] || exit 0
# A stopped subagent may still hand its write-up back to the main session.
case "$tool" in SubagentHandback) exit 0 ;; esac

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

out=$(jq -rn \
  --argjson now "$(date +%s)" \
  --argjson stale "${USAGE_BRAKE_STALE_SECS:-900}" \
  --argjson b "$(cat "$bf" 2>/dev/null || echo null)" \
  --argjson u1 "$(cat "$D/usage/$sid.json" 2>/dev/null || echo null)" \
  --argjson u2 "$(cat "$D/usage/latest.json" 2>/dev/null || echo null)" \
  --arg mode hook --argjson arg null \
  -f "$D/bin/brake.jq" 2>/dev/null) \
  || deny "Usage brake is armed but could not read its state files in $D. Refusing tool calls to be safe. Write up where you are and stop. (The user can run /limit off.)"

IFS=$'\t' read -r decision newb hookjson <<<"$out"

if [ "$newb" != "-" ] && [ -n "$newb" ]; then
  tmp=$(mktemp "$D/budget/.tmp.XXXXXX") && printf '%s\n' "$newb" >"$tmp" && mv -f "$tmp" "$bf"
fi

if [ "$decision" = "allow" ]; then exit 0; fi
if [ "$decision" = "deny" ] && [ -n "$hookjson" ] && [ "$hookjson" != "-" ]; then
  printf '%s\n' "$hookjson"
  exit 0
fi
deny "Usage brake hit an unexpected state. Refusing tool calls to be safe. Write up where you are and stop. (The user can run /limit off.)"
