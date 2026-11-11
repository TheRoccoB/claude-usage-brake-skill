#!/usr/bin/env bash
# claude-usage-brake installer.
#   ./install.sh               install, or update in place (safe to re-run)
#   ./install.sh --uninstall   remove it and restore your original status line
#   ./install.sh --dry-run     show what would change, change nothing
#
# Changes, all under ${CLAUDE_CONFIG_DIR:-~/.claude}:
#   skills/limit/              the /limit command
#   usage-brake/               hook + status line scripts, and runtime state
#   settings.json              statusLine -> wrapper (your command still runs),
#                              plus one PreToolUse hook. Backed up first.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
D="$C/usage-brake"
S="$C/settings.json"
SKILL="$C/skills/limit"
WRAP="$D/bin/statusline.sh"
HOOK="$D/bin/pretooluse.sh"
MARK="usage-brake/bin/"   # identifies our entries in settings.json

mode=install
case "${1:-}" in
  --uninstall|uninstall) mode=uninstall ;;
  --dry-run) mode=dry ;;
  ""|--install|install) ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq; Debian/Ubuntu: apt install jq)."

if [ -f "$S" ]; then
  jq -e 'type == "object"' "$S" >/dev/null 2>&1 || die "$S is not a plain JSON object (comments?). Not touching it."
  cur=$(cat "$S")
else
  cur='{}'
fi

write_settings() { # new-json
  local new=$1
  if [ "$new" = "$cur" ]; then echo "settings.json: no change needed"; return; fi
  if [ -f "$S" ]; then
    local bak; bak="$S.usage-brake-backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "$S" "$bak"
    echo "settings.json: backed up to $bak"
  fi
  mkdir -p "$C"
  local tmp; tmp=$(mktemp "$C/.settings.json.XXXXXX")
  printf '%s\n' "$new" >"$tmp"
  [ -f "$S" ] && chmod "$(perms "$S")" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$S"
  echo "settings.json: updated"
}
perms() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }

# Is the current status line ours already?
ours=$(jq -r --arg m "$MARK" '(.statusLine.command // "") | contains($m)' <<<"$cur")

if [ "$mode" = uninstall ]; then
  new="$cur"
  if [ "$ours" = true ]; then
    if [ -f "$D/orig-statusline.json" ]; then
      orig=$(cat "$D/orig-statusline.json")
      new=$(jq --argjson o "$orig" 'if $o == null then del(.statusLine) else .statusLine = $o end' <<<"$new")
      echo "status line: restoring your original"
    else
      new=$(jq 'del(.statusLine)' <<<"$new")
      echo "status line: original not recorded, removing the wrapper"
    fi
  else
    echo "status line: not ours, leaving it alone"
  fi
  new=$(jq --arg m "$MARK" '
    if .hooks.PreToolUse then
      .hooks.PreToolUse |= map(.hooks |= map(select((.command // "") | contains($m) | not)) | select(.hooks | length > 0))
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end' <<<"$new")
  write_settings "$new"
  rm -rf "$SKILL" "$D"
  echo "removed $SKILL and $D"
  echo "Done. Open sessions keep the old status line until restarted."
  exit 0
fi

# ---- install / update ----
if [ "$ours" = true ]; then
  orig_sl=$(cat "$D/orig-statusline.json" 2>/dev/null || echo null)
else
  orig_sl=$(jq -c '.statusLine // null' <<<"$cur")
fi
orig_cmd=$(jq -r 'if type == "object" then .command // "" else "" end' <<<"$orig_sl")

new=$(jq --arg w "$WRAP" --arg h "$HOOK" --arg m "$MARK" --argjson o "$orig_sl" '
  # status line: keep your options (padding etc.), swap in the wrapper,
  # and re-run it every 60 s if you had no refreshInterval, so an armed
  # brake never mistakes an idle session for a broken status line.
  .statusLine = ((if ($o | type) == "object" then $o else {} end)
                 + {type: "command", command: $w}
                 | if .refreshInterval == null then .refreshInterval = 60 else . end)
  # PreToolUse hook, once
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // [])
      | map(.hooks |= map(select((.command // "") | contains($m) | not)) | select(.hooks | length > 0))
      + [{matcher: "*", hooks: [{type: "command", command: $h, timeout: 10}]}])
' <<<"$cur")

if [ "$mode" = dry ]; then
  echo "Would install: $SKILL/, $D/bin/"
  echo "Would wrap status line command: ${orig_cmd:-<none>}"
  echo "settings.json diff (current -> new):"
  diff <(jq -S . <<<"$cur") <(jq -S . <<<"$new") || true
  exit 0
fi

mkdir -p "$D/bin" "$D/budget" "$D/usage" "$SKILL"
cp "$SRC/bin/brake.jq" "$SRC/bin/pretooluse.sh" "$SRC/bin/statusline.sh" "$D/bin/"
cp "$SRC/skills/limit/SKILL.md" "$SRC/skills/limit/limit.sh" "$SKILL/"
chmod +x "$D/bin/"*.sh "$SKILL/limit.sh"
printf '%s\n' "$orig_sl" >"$D/orig-statusline.json"
printf '%s' "$orig_cmd" >"$D/orig-command"
echo "installed $SKILL/ and $D/bin/"
echo "status line: wrapping ${orig_cmd:-<none, the wrapper only shows the brake line>}"
write_settings "$new"
cat <<EOF
Done. In a new Claude Code session (or after the status line next refreshes):
  /limit 10          stop tool calls after 10 more points of weekly usage
  /limit             status
  /limit off         disarm
Uninstall: $SRC/install.sh --uninstall
EOF
