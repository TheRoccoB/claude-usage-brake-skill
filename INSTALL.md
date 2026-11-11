# Installing claude-usage-brake-skill (instructions for Claude Code)

You are installing a `/limit` command that stops a Claude Code session after it uses N points of the user's weekly plan usage. Follow these steps.

## 1. Check prerequisites

- `bash` and `jq` are present (`command -v jq`). If jq is missing, tell the user how to install it (`brew install jq` on macOS, or their package manager) and stop.
- They use a claude.ai subscription (Pro/Max/Ultra). Usage numbers don't exist for API-key logins. If you can't tell, mention it.

## 2. Get the code

```sh
git clone https://github.com/TheRoccoB/claude-usage-brake-skill ~/.claude-usage-brake-skill
```

If that directory already exists, run `git -C ~/.claude-usage-brake-skill pull` instead.

## 3. Show the user what will change, then ask

Run the dry run and show its output:

```sh
~/.claude-usage-brake-skill/install.sh --dry-run
```

Tell the user, in plain words:

- It adds `~/.claude/skills/limit/` (the `/limit` command) and `~/.claude/usage-brake/` (two small scripts plus state). If `CLAUDE_CONFIG_DIR` is set, both go under that directory instead of `~/.claude`.
- In `settings.json` (backed up first):
  - Their status line command is replaced by a wrapper that **still runs their command** and shows its output unchanged. The wrapper also saves the plan usage numbers. If they had no `refreshInterval`, it's set to 60 seconds.
  - One `PreToolUse` hook is added. Existing hooks are kept.
- Sessions that haven't run `/limit` are not affected.
- Uninstall: `~/.claude-usage-brake-skill/install.sh --uninstall` restores the original status line.

Ask for confirmation before continuing.

## 4. Install

```sh
~/.claude-usage-brake-skill/install.sh
```

## 5. Tell the user how to use it

- `/limit 10`: stop tool calls after 10 more points of weekly usage. Add `--max 70` for a hard ceiling.
- `/limit` shows status. `/limit off` disarms.
- It only works where the status line runs (interactive sessions). It can overshoot by about a turn.
- Weekly usage is plan-wide, so other sessions count toward the budget.
- New sessions get `/limit`. Open sessions pick up the status line change when it next refreshes.
