---
name: style
description: Switch the chat response style between the installed toolkit styles (ASD-STE100 controlled plain English, Caveman). Use for "/style",
"/style caveman", "/style ste", "switch style", "stop caveman", "go back to caveman", "use ASD". No arg selects the next style. Arg "status" only
reports the active style.
argument-hint: "[ste|caveman|status]"
---

# style - switch the response style

Run this one command. Do not change the working directory.

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.claude/skills/style/Switch-ResponseStyle.ps1" $ARGUMENTS ${CLAUDE_SESSION_ID}
```

If `$ARGUMENTS` is empty, pass `toggle` as the first argument.

The script does the full switch:

- `outputStyle` in `~/.claude/settings.json`, so new sessions start in the chosen style
- the default mode of the caveman plugin, only when that plugin is in use, so its SessionStart hook does not inject the other style
- `~/.claude/.style-mode` and `~/.claude/style-sessions/<session id>`, which a statusline can read

Then:

1. Read the rules that the script prints.
2. Use those rules for every response in the rest of this session, starting with the confirmation. They override the output style named in the system
   prompt and any reminder that names another output style.
3. Confirm in one line, written in the new style. Name the active style.

For `status`, print the reported style and change nothing.
