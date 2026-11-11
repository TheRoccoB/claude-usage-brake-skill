> **Install by asking Claude Code:** `Install claude-usage-brake-skill for me: read https://github.com/TheRoccoB/claude-usage-brake-skill/blob/main/INSTALL.md, tell me what it will change, then do it.`

# claude-usage-brake-skill

A `/limit` command for Claude Code that stops a session after it has used **N points of your plan's weekly usage**.

You can start a long agent run before bed without waking up at 100% of your weekly limit.

```
/limit 10          # stop after 10 more points (e.g. 22% → 32%)
/limit 10 --max 70 # ...or once weekly usage reaches 70%, whichever comes first
/limit             # status: baseline, used, left, reset time
/limit off         # disarm
```

Once the budget is used up, every tool call in that session (including subagents) is refused with:

> Usage limit reached (22% → 32% weekly, budget 10 points). Write up where you are and stop.

Claude can still reply, so it leaves you a handover note instead of stopping mid-edit.

Unofficial. Not affiliated with or endorsed by Anthropic.

## Install

You need a claude.ai subscription (Pro / Max / Ultra), `bash`, and `jq`. It works on Linux and macOS.

```sh
git clone https://github.com/TheRoccoB/claude-usage-brake-skill ~/.claude-usage-brake-skill
~/.claude-usage-brake-skill/install.sh            # add --dry-run to preview
```

New sessions get `/limit`. Sessions that are already open pick up the status line wrapper when it next refreshes.

To uninstall (restores your original status line and removes everything it added):

```sh
~/.claude-usage-brake-skill/install.sh --uninstall
```

The installer backs up `settings.json` first (the backups stay after uninstall). It keeps your existing hooks and your status line: it adds one hook and wraps your status line. Re-running it is safe. It respects `CLAUDE_CONFIG_DIR` and symlinked settings files, and it refuses to overwrite an existing `limit` skill that isn't its own.

## How it works

Claude Code doesn't expose plan usage to hooks, but it does pass it to the status line. So there are three small parts:

1. **Status line wrapper.** Claude Code sends the status line `rate_limits.seven_day.used_percentage` (and `five_hour`, when your plan has one). The wrapper saves those numbers to `~/.claude/usage-brake/usage/`, then runs **your** status line command and passes its output through unchanged. While `/limit` is armed it adds one line, such as `brake 3/10 pts`.
2. **`/limit` skill.** It records the current weekly % as this session's baseline, plus your budget, in `~/.claude/usage-brake/budget/<session-id>.json`. It runs as a script before Claude sees anything, so arming takes no tool calls. It's marked `disable-model-invocation`, so Claude doesn't run `/limit` by itself.
3. **PreToolUse hook.** It runs before every tool call, including MCP tools and tools inside subagents. If no session has `/limit` armed, it exits immediately. Otherwise, once usage reaches baseline + N (or `--max`), it denies the call with the message above. The one exception is a subagent's hand-back of its final report, so a stopped subagent can still say where it got to.

## Things to know

- **Best effort. It can overshoot by about a turn.** Usage numbers arrive with each API response, and the hook can only refuse the *next* tool call. A single long response still finishes.
- **Weekly % is plan-wide.** Your other sessions count toward this session's budget: `/limit 10` trips when the plan as a whole has moved 10 points, whoever used them. This errs toward stopping early.
- **It needs the status line running.** The status line is where the numbers come from. They only appear for claude.ai subscribers, after the session's first reply. Headless `claude -p` has no status line, so an armed brake refuses everything there. A project's `.claude/settings.json` or `settings.local.json` can set its own `statusLine`, which bypasses the wrapper. Then an armed brake goes stale and refuses everything after 15 minutes.
- **Per session.** The budget belongs to the session that ran `/limit`. A new session, or anything that starts a new session id, starts unbraked, so run `/limit` again there.
- **It fails safe.** If the brake is armed and the newest usage reading is missing or older than 15 minutes, tool calls are refused. The installer sets `statusLine.refreshInterval: 60` (only if you had none), so an idle session doesn't look stale. `/limit off` always works, even while tripped.
- **The 5-hour window is optional.** The budget is measured against the weekly window. If your plan only reports a 5-hour window, `/limit` uses that instead. `/limit 10 --5h` picks it explicitly. If the weekly window resets while armed, points used before the reset still count.
- Tested with Claude Code 2.1.319 and jq 1.8. It should work with jq 1.6+ and macOS's built-in bash 3.2.
- **It's a seatbelt, not a lock.** Before the limit trips, Claude could run the `/limit` script itself or delete the budget file. It's there to stop runaway usage, not an adversarial model.
- Claude Code's `autoContinueAtUsageLimit` (on by default) resumes work after a real usage limit resets. That's a different thing: this brake stops you well before the real limit.

## Files

| Path | What |
| --- | --- |
| `skills/limit/` | The `/limit` skill (installed to `~/.claude/skills/limit/`) |
| `bin/statusline.sh` | Status line wrapper |
| `bin/pretooluse.sh` | The hook |
| `bin/brake.jq` | Shared logic: budget maths, messages |
| `install.sh` | Install, update, `--uninstall`, `--dry-run` |
| `test/run-tests.sh` | Offline tests against a temp config dir |

Environment knobs: `USAGE_BRAKE_STALE_SECS` (default 900), `USAGE_BRAKE_NO_INDICATOR=1` (hide the status line indicator), `USAGE_BRAKE_DIR` (state dir, mainly for tests).

## Why not a plugin?

Plugins can ship skills and hooks, but not a status line. Claude Code drops `statusLine` from plugin settings. The status line is the only place the usage numbers appear, so an install script is needed.

## License

MIT
