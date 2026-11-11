#!/usr/bin/env bash
# /limit backend. Called by SKILL.md before the model sees anything:
#   limit.sh <session_id> [N] [--max P] [--5h|--7d] | off | help
# Always exits 0: a non-zero exit would abort the skill without output.
D="${USAGE_BRAKE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-brake}"
J="$D/bin/brake.jq"
sid="${1:-}"; shift 2>/dev/null

say() { printf '%s\n' "$*"; exit 0; }
usage="Usage: /limit N [--max P] [--5h]   stop after N more points of plan usage
       /limit --max P                  stop once usage reaches P%
       /limit                          show status
       /limit off                      disarm"

case "$sid" in ''|*[!A-Za-z0-9_-]*) say "Usage brake: no session id from Claude Code (got '$sid'). Is your Claude Code up to date?" ;; esac
command -v jq >/dev/null 2>&1 || say "Usage brake: jq is not installed."
[ -f "$J" ] || say "Usage brake: not installed ($J missing). Run install.sh from claude-usage-brake-skill."
mkdir -p "$D/budget" "$D/usage" || say "Usage brake: cannot create $D."

bf="$D/budget/$sid.json"
num_re='^[0-9]+([.][0-9]+)?$'

run_jq() { # mode argjson
  jq -rn \
    --argjson now "$(date +%s)" \
    --argjson stale "${USAGE_BRAKE_STALE_SECS:-900}" \
    --argjson b "$(cat "$bf" 2>/dev/null || echo null)" \
    --argjson u1 "$(cat "$D/usage/$sid.json" 2>/dev/null || echo null)" \
    --argjson u2 "$(cat "$D/usage/latest.json" 2>/dev/null || echo null)" \
    --arg mode "$1" --argjson arg "$2" \
    -f "$J"
}

# Housekeeping: drop usage readings untouched for 8 days, and budgets whose
# session's status line has not run for 2 days (the session is gone; an open
# session refreshes its reading every minute).
find "$D/usage" -type f -name '*.json' ! -name latest.json -mtime +8 -exec rm -f {} + 2>/dev/null
for f in "$D"/budget/*.json; do
  [ -f "$f" ] || continue
  s=$(basename "$f" .json)
  [ "$s" = "$sid" ] && continue
  if [ -z "$(find "$D/usage/$s.json" -mtime -2 2>/dev/null)" ] && [ -n "$(find "$f" -mtime +2 2>/dev/null)" ]; then rm -f "$f"; fi
done

budget=null; max=null; window=null; action=status
while [ $# -gt 0 ]; do
  case "$1" in
    off|disarm|stop|clear) action=off ;;
    help|-h|--help) say "$usage" ;;
    status) ;;
    --max) shift; [[ "${1:-}" =~ $num_re ]] || say "--max needs a percentage, e.g. --max 70"$'\n'"$usage"; max=$1; action=arm ;;
    --max=*) v=${1#--max=}; [[ "$v" =~ $num_re ]] || say "$usage"; max=$v; action=arm ;;
    --5h) window='"five_hour"' ;;
    --7d|--week|--weekly) window='"seven_day"' ;;
    *) [[ "$1" =~ $num_re ]] || say "Unknown argument '$1'."$'\n'"$usage"; budget=$1; action=arm ;;
  esac
  shift
done

case "$action" in
  off)
    if [ -f "$bf" ]; then rm -f "$bf"; echo "Usage brake: disarmed for this session."
    else echo "Usage brake: was not armed in this session."; fi
    ;;
  arm)
    [ "$budget" = null ] || awk "BEGIN{exit !($budget > 0)}" || say "The budget must be more than 0."
    nb=$(run_jq arm "{\"budget\":$budget,\"max\":$max,\"window\":$window}") || say "Usage brake: failed to arm (jq error)."
    tmp=$(mktemp "$D/budget/.tmp.XXXXXX") && printf '%s\n' "$nb" >"$tmp" && mv -f "$tmp" "$bf" || say "Usage brake: cannot write $bf."
    run_jq status null
    case "$window" in
      '"five_hour"') ;;
      *) echo "Note: weekly % is plan-wide, so your other sessions count toward this budget." ;;
    esac
    ;;
  *)
    run_jq status null
    ;;
esac
exit 0
