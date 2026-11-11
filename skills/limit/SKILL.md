---
name: limit
description: Usage brake (claude-usage-brake). Stop this session's tool calls after it uses N more points of your Claude plan's weekly usage. /limit N [--max P], /limit (status), /limit off.
argument-hint: "N [--max P] [--5h] | off"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/limit.sh:*)
---
!`"${CLAUDE_SKILL_DIR}/limit.sh" "${CLAUDE_SESSION_ID}" $ARGUMENTS`

The usage brake printed the text above. Show it to the user exactly as printed, inside a code block, with no other commentary and no tool calls.
