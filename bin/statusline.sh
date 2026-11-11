#!/usr/bin/env bash
# claude-usage-brake status line wrapper.
# 1. Saves this session's plan usage (rate_limits) for the PreToolUse hook.
# 2. Runs your original status line command and passes its output through.
# 3. While /limit is armed in this session, adds one short "brake" line.
D="${USAGE_BRAKE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-brake}"
input=$(cat)

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
case "$sid" in *[!A-Za-z0-9_-]*) sid="" ;; esac

# 1. Record usage first (Claude Code cancels slow status line scripts).
case "$input" in
  *'"rate_limits"'*)
    if [ -n "$sid" ] && mkdir -p "$D/usage" 2>/dev/null; then
      rec=$(jq -rn --argjson now "$(date +%s)" --argjson stale 0 \
              --argjson b null --argjson u1 null \
              --argjson u2 "$(cat "$D/usage/latest.json" 2>/dev/null || echo null)" \
              --arg mode record --argjson arg "$input" \
              -f "$D/bin/brake.jq" 2>/dev/null)
      own=${rec%%$'\n'*}; latest=${rec#*$'\n'}
      if [ -n "$own" ] && [ "$own" != "$rec" ]; then
        tmp=$(mktemp "$D/usage/.tmp.XXXXXX") && printf '%s\n' "$own" >"$tmp" && mv -f "$tmp" "$D/usage/$sid.json"
        tmp=$(mktemp "$D/usage/.tmp.XXXXXX") && printf '%s\n' "$latest" >"$tmp" && mv -f "$tmp" "$D/usage/latest.json"
      fi
    fi
    ;;
esac

# 2. The original status line, unchanged.
orig=""
[ -f "$D/orig-command" ] && orig=$(cat "$D/orig-command")
if [ -n "$orig" ]; then
  printf '%s' "$input" | bash -c "$orig"
  rc=$?
else
  rc=0
fi

# 3. Brake indicator, only for sessions that armed /limit.
if [ -n "$sid" ] && [ -f "$D/budget/$sid.json" ] && [ -z "${USAGE_BRAKE_NO_INDICATOR:-}" ]; then
  line=$(jq -rn \
    --argjson now "$(date +%s)" \
    --argjson stale "${USAGE_BRAKE_STALE_SECS:-900}" \
    --argjson b "$(cat "$D/budget/$sid.json" 2>/dev/null || echo null)" \
    --argjson u1 "$(cat "$D/usage/$sid.json" 2>/dev/null || echo null)" \
    --argjson u2 "$(cat "$D/usage/latest.json" 2>/dev/null || echo null)" \
    --arg mode line --argjson arg null \
    -f "$D/bin/brake.jq" 2>/dev/null)
  if [ -n "$line" ]; then
    case "$line" in
      "brake "*) printf '\n\033[2m%s\033[0m' "$line" ;;
      *)         printf '\n\033[31m%s\033[0m' "$line" ;;
    esac
  fi
fi
exit $rc
