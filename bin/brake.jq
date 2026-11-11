# claude-usage-brake: shared logic for the hook, the status line and /limit.
#
# Arguments (all passed with --argjson):
#   $now    current epoch seconds
#   $b      this session's budget object, or null
#   $u1 $u2 usage readings (this session's, and the latest from any session), or null
#   $stale  seconds after which a reading counts as stale
#   $mode   "hook" | "status" | "line" | "arm"
#   $arg    mode-specific object (arm: {budget, max, window})
#
# Usage reading:  {ts, session_id, seven_day:{pct,resets_at}|null, five_hour:{...}|null}
# Budget object:  {window, budget, max, baseline, start, carried, last_pct, resets_at, armed_at}
#   baseline  % when armed (for messages); start = baseline, or 0 after a window reset
#   carried   points used in earlier windows (if the window reset while armed)

def fmt: if type != "number" then "?" elif . == floor then tostring else (. * 10 | round / 10 | tostring) end;
def wname: if . == "five_hour" then "5-hour" else "weekly" end;
def ago: if . < 90 then "\(. | floor)s" elif . < 5400 then "\(. / 60 | floor)m" else "\(. / 3600 | floor)h" end;
def until_: (. - $now) as $s
  | if $s <= 0 then "now"
    elif $s < 3600 then "in \($s / 60 | floor)m"
    elif $s < 86400 then "in \($s / 3600 | floor)h \(($s % 3600) / 60 | floor)m"
    else "in \($s / 86400 | floor)d \(($s % 86400) / 3600 | floor)h" end;
def when_: "\(localtime | strftime("%a %H:%M")) (\(until_))";

# Readings are merged, not just "newest wins": an idle session's status line
# keeps re-rendering its cached (older, lower) numbers with a new timestamp.
# Within one window usage only goes up, so take the latest window, then the
# highest %. Windows past their reset time are dropped (Claude Code does too).
def wmerge($x; $y):
  [$x, $y]
  | map(select(type == "object" and (.pct | type) == "number" and ((.resets_at // ($now + 1)) > $now)))
  | if length == 0 then null
    else (map(.resets_at // 0) | max) as $ra
      | map(select((.resets_at // 0) >= $ra - 300)) | max_by(.pct)
    end;
def umerge($x; $y):
  [$x, $y] | map(select(type == "object" and (.ts | type) == "number"))
  | if length == 0 then null
    else {ts: (map(.ts) | max), seven_day: wmerge($x.seven_day; $y.seven_day), five_hour: wmerge($x.five_hour; $y.five_hour)}
    end;
def fresh: umerge($u1; $u2);

# Evaluate the budget against the freshest reading. Returns
# {state, b (possibly updated), u, r, used, age}
# state: ok | limit | ceiling | stale | nodata | nowindow
def evaluate:
  fresh as $u
  | if $u == null then {state: "nodata", b: $b}
    elif ($now - $u.ts) > $stale then {state: "stale", b: $b, u: $u, age: ($now - $u.ts)}
    else
      $u[$b.window] as $r
      | if ($r | type) != "object" or ($r.pct | type) != "number" then {state: "nowindow", b: $b, u: $u, age: ($now - $u.ts)}
        else
          ($b
            # armed before any reading existed: take the first one as baseline
            | if .start == null then .start = $r.pct | .baseline = $r.pct | .last_pct = $r.pct | .resets_at = $r.resets_at else . end
            # the window rolled over while armed: carry what was used before it
            | if ($r.resets_at // 0) > ((.resets_at // 0) + 300) and .resets_at != null
              then .carried = ((.carried // 0) + ((.last_pct // .start) - .start)) | .start = 0 | .resets_at = $r.resets_at
              else . end
            | .last_pct = $r.pct) as $nb
          | (($nb.carried // 0) + $r.pct - $nb.start) as $used
          | {b: $nb, u: $u, r: $r, used: $used, age: ($now - $u.ts),
             state: (if $nb.budget != null and $used >= $nb.budget then "limit"
                     elif $nb.max != null and $r.pct >= $nb.max then "ceiling"
                     else "ok" end)}
        end
    end;

def stop_tail: " Write up where you are and stop.";
def reason($e):
  ($b.window | wname) as $wn
  | if $e.state == "limit" then
      "Usage limit reached (\($e.b.baseline | fmt)% → \($e.r.pct | fmt)% \($wn), budget \($e.b.budget | fmt) points)." + stop_tail
    elif $e.state == "ceiling" then
      "Usage ceiling reached (\($wn) usage \($e.r.pct | fmt)% ≥ --max \($e.b.max | fmt)%)." + stop_tail
    elif $e.state == "stale" then
      "Usage brake is armed but the latest usage reading is \($e.age | ago) old, so it can't tell how much is left. Refusing tool calls to be safe." + stop_tail + " (The user can run /limit off.)"
    elif $e.state == "nowindow" then
      "Usage brake is armed but the latest usage reading has no \($wn) figure. Refusing tool calls to be safe." + stop_tail + " (The user can run /limit off.)"
    else
      "Usage brake is armed but there is no usage reading (it needs the usage-brake status line and a claude.ai subscription). Refusing tool calls to be safe." + stop_tail + " (The user can run /limit off.)"
    end;

def status_text:
  fresh as $u
  | if $b == null then
      ([ "Usage brake: off." ]
       + (if $u == null then ["No usage reading yet. Readings come from the status line after the first reply, on claude.ai subscriptions only."]
          else
            [ (if $u.seven_day then "  weekly  \($u.seven_day.pct | fmt)%, resets \($u.seven_day.resets_at | when_)" else empty end),
              (if $u.five_hour then "  5-hour  \($u.five_hour.pct | fmt)%, resets \($u.five_hour.resets_at | when_)" else empty end),
              "  reading \(($now - $u.ts) | ago) old" ]
          end)
       + ["Arm it with /limit N (stop after N more points), optionally --max P (hard ceiling)."])
      | join("\n")
    else
      evaluate as $e
      | ($b.window | wname) as $wn
      | ([ "Usage brake: " + (if $e.state == "ok" then "ARMED" else "TRIPPED, tool calls are refused" end) + " (\($wn) window)" ]
         + (if $e.r then
              [ "  baseline \($e.b.baseline | fmt)%  now \($e.r.pct | fmt)%",
                (if $e.b.budget != null then
                   "  used \($e.used | fmt) of \($e.b.budget | fmt) points, \([($e.b.budget - $e.used), 0] | max | fmt) left, stops at \(($e.b.baseline + $e.b.budget - ($e.b.carried // 0)) | fmt)%"
                   + (if ($e.b.carried // 0) > 0 then " of the new window (\($e.b.carried | fmt) carried over a reset)" else "" end)
                 else empty end),
                (if $e.b.max != null then "  ceiling \($e.b.max | fmt)%" else empty end),
                "  resets \($e.r.resets_at | when_)",
                "  reading \($e.age | ago) old" ]
            else
              [ (if $e.b.baseline != null then "  baseline \($e.b.baseline | fmt)%" else "  baseline: pending (taken from the next usage reading)" end),
                (if $e.b.budget != null then "  budget \($e.b.budget | fmt) points" else empty end),
                (if $e.b.max != null then "  ceiling \($e.b.max | fmt)%" else empty end),
                (if $e.state == "nodata" then "  No usage reading yet. If this persists, check that the usage-brake status line is installed."
                 else "  " + reason($e) end) ]
            end)
         + ["/limit off disarms it."])
      | join("\n")
    end;

if $mode == "hook" then
  evaluate as $e
  | [ (if $e.state == "ok" then "allow" else "deny" end),
      (if $e.b != $b then ($e.b | tojson) else "-" end),
      (if $e.state == "ok" then "-"
       else {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason($e)}} | tojson end) ]
  | join("\t")

elif $mode == "status" then status_text

elif $mode == "line" then
  # compact indicator appended to the status line while armed
  evaluate as $e
  | if $e.state == "ok" then
      "brake " + ([ (if $e.b.budget != null then "\($e.used | fmt)/\($e.b.budget | fmt) pts" else empty end),
                    (if $e.b.max != null then "max \($e.b.max | fmt)%" else empty end) ] | join(" · "))
    elif $e.state == "limit" or $e.state == "ceiling" then "brake: limit reached, tools refused"
    else "brake: no fresh usage reading, tools refused" end

elif $mode == "record" then
  # $arg = raw status line JSON, $u2 = current latest.json.
  # Line 1: this session's reading. Line 2: merged plan-wide latest.
  def w: if type == "object" and (.used_percentage | type) == "number"
         then {pct: .used_percentage, resets_at: .resets_at} else null end;
  {ts: $now, session_id: $arg.session_id,
   seven_day: ($arg.rate_limits.seven_day | w),
   five_hour: ($arg.rate_limits.five_hour | w)}
  | select(.seven_day != null or .five_hour != null)
  | (tojson, (umerge(.; $u2) | tojson))

elif $mode == "arm" then
  fresh as $u
  | ( if $arg.window then $arg.window
      elif $u != null and $u.seven_day == null and $u.five_hour != null then "five_hour"
      else "seven_day" end ) as $w
  | (if $u != null and ($now - $u.ts) <= $stale then $u[$w] else null end) as $r
  | { window: $w, budget: $arg.budget, max: $arg.max, armed_at: $now,
      baseline: $r.pct, start: $r.pct, last_pct: $r.pct, resets_at: $r.resets_at, carried: 0 }
  | tojson

else error("unknown mode") end
