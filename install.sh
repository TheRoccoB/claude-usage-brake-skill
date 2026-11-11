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
SKILL_MARK="claude-usage-brake"   # identifies our SKILL.md

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

case "$C" in *"'"*) die "config dir path contains a single quote: $C" ;; esac
q() { printf "'%s'" "$1"; }   # quote a path for a settings.json command

if [ -f "$S" ]; then
  jq -e 'type == "object"' "$S" >/dev/null 2>&1 || die "$S is not a plain JSON object (comments?). Not touching it."
  cur=$(cat "$S")
else
  cur='{}'
fi

perms() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
write_settings() { # new-json
  local new=$1
  if [ "$new" = "$cur" ]; then echo "settings.json: no change needed"; return; fi
  if [ -f "$S" ]; then
    local bak; bak="$S.usage-brake-backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "$S" "$bak"
    echo "settings.json: backed up to $bak"
  fi
  mkdir -p "$C"
  if [ -L "$S" ]; then
    # symlinked (dotfile manager): write through the link, keep it a link
    printf '%s\n' "$new" >"$S"
  else
    local tmp; tmp=$(mktemp "$C/.settings.json.XXXXXX")
    printf '%s\n' "$new" >"$tmp"
    if [ -f "$S" ]; then chmod "$(perms "$S")" "$tmp" 2>/dev/null || true; fi
    mv -f "$tmp" "$S"
  fi
  echo "settings.json: updated"
}

# jq: drop our hook commands; drop an entry only if it held ours and is now empty.
STRIP='def strip($m):
  map(if type == "object" and (.hooks | type) == "array"
          and any(.hooks[]; (.command? // "") | tostring | contains($m))
      then .hooks |= map(select((.command? // "") | tostring | contains($m) | not))
           | select(.hooks | length > 0)
      else . end);'

ours=$(jq -r --arg m "$MARK" '(.statusLine | if type == "object" then (.command // "") else "" end) | tostring | contains($m)' <<<"$cur")

our_skill() { [ -f "$SKILL/SKILL.md" ] && grep -q "$SKILL_MARK" "$SKILL/SKILL.md"; }

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
  new=$(jq --arg m "$MARK" "$STRIP"'
    if (.hooks | type) == "object" and (.hooks.PreToolUse | type) == "array" then
      .hooks.PreToolUse |= strip($m)
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end' <<<"$new")
  write_settings "$new"
  if our_skill; then
    rm -f "$SKILL/SKILL.md" "$SKILL/limit.sh"; rmdir "$SKILL" 2>/dev/null || true
    echo "removed $SKILL"
  fi
  rm -rf "$D"
  echo "removed $D"
  echo "Done. settings.json backups (settings.json.usage-brake-backup.*) are left in $C."
  echo "Open sessions keep the old status line until it next refreshes or they restart."
  exit 0
fi

# ---- install / update ----
if [ -e "$SKILL" ] && ! our_skill; then
  die "$SKILL already exists and isn't ours. Move it aside and re-run."
fi

if [ "$ours" = true ]; then
  if [ -f "$D/orig-statusline.json" ]; then
    orig_sl=$(cat "$D/orig-statusline.json")
  else
    echo "warning: settings point at the usage-brake wrapper but the original status line record is gone; treating it as none." >&2
    orig_sl=null
  fi
else
  orig_sl=$(jq -c '.statusLine | if type == "object" then . else null end' <<<"$cur")
fi
orig_cmd=$(jq -r 'if type == "object" then .command // "" else "" end' <<<"$orig_sl")

new=$(jq --arg w "$(q "$WRAP")" --arg h "$(q "$HOOK")" --arg m "$MARK" --argjson o "$orig_sl" "$STRIP"'
  # status line: keep your options (padding etc.), swap in the wrapper,
  # and re-run it every 60 s if you had no refreshInterval, so an armed
  # brake never mistakes an idle session for a broken status line.
  .statusLine = ((if ($o | type) == "object" then $o else {} end)
                 + {type: "command", command: $w}
                 | if .refreshInterval == null then .refreshInterval = 60 else . end)
  # PreToolUse hook, once
  | .hooks = (if (.hooks | type) == "object" then .hooks else {} end)
  | .hooks.PreToolUse = ((if (.hooks.PreToolUse | type) == "array" then .hooks.PreToolUse else [] end)
      | strip($m)
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
