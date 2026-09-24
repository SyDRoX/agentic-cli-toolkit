# agentic-cli-notify

Desktop notification system for Claude Code on Windows Terminal.

## Architecture

Hooks (cmd.exe) -> notify.ps1 (PowerShell) -> popup.ps1 (WPF)

- `attention.cmd` / `resume.cmd` are thin cmd.exe wrappers required because Claude Code hooks run via cmd.exe on Windows
- Every agent maps onto the same two actions (`attention`, `resume`) through its own adapter:
  - Claude Code: `attention.cmd` / `resume.cmd` from `~/.claude/settings.json`
  - Codex: `codex-hook.ps1` from `$CODEX_HOME/hooks.json` (event read from the stdin payload)
  - Cursor Agent: `cursor-hook.ps1` from `~/.cursor/hooks.json`, events `stop` and `beforeSubmitPrompt`; the event is passed as `-Action` because the payload field name differs between Cursor versions
  - pi: `pi-extension/agentic-cli-notify.ts`, installed to `~/.pi/agent/extensions/`, on `agent_settled` / `ui_prompt_start` (attention) and `session_start` / `before_agent_start` / `ui_prompt_end` (resume). Attention is gated on a turn the user started: the extension arms on `before_agent_start` and disarms on `agent_settled`, so pi's own startup dialogs (project trust, pickers) raise nothing. A turn the user aborted with escape sends `resume`, not `attention` - `agent_settled` carries no outcome, so the stop reason is read from `message_end`. Spawn the notifier without `detached`: DETACHED_PROCESS gives powershell.exe no console and it exits 0 without running the script. Use `windowsHide` so the child gets its own hidden console and does not rename the WT tab.
- `notify.ps1 -Agent` accepts `Claude`, `Codex`, `Pi`, `Cursor`; the value is only a popup title
- `notify.ps1` is the dispatcher: flashes the taskbar, launches/kills popup processes
- `popup.ps1` is a standalone WPF window launched as a separate PowerShell process with `-STA` flag
- `save-hwnd.exe` is a .NET Framework 4 console app compiled from `SaveHwnd.cs`
- `setup.ps1` is the user-facing setup script that runs `save-hwnd.exe` and stores results per-session

## Key Constraints

- ConPTY means `GetConsoleWindow()` returns 0 from hook subprocesses
- All WT windows share one UI thread; can't distinguish by thread ID
- `GetForegroundWindow()` unreliable from hook subprocesses (timing)
- Tab names change dynamically; tab INDEX (position) is used instead
- PowerShell 5.1's Add-Type compiler doesn't support C# 7 features (no `out _`)
- `.NET Framework 4 csc.exe` is at `/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe`
- UI Automation DLLs at `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomation*.dll`
- WPF `Children.Add()` returns an int; suppress with `$null =` or ShowDialog breaks

## State Files

All runtime state is in `~/.claude/hooks/agentic-cli-notify/`, keyed by `WT_SESSION`:

- `.hwnd-{session}` - Window handle
- `.tabindex-{session}` - Tab position (1-based)
- `.popup-{session}.pid` - Active popup PID
- `.slots/{screen}-{pid}.slot` - Stack slot claim per live popup, holding `<claimTicks>|<height>`. Popups stack by claim order and reflow down when a lower popup closes; claims of dead processes are purged on the next poll.

## Building

```cmd
build.cmd
```

Requires .NET Framework 4 (ships with Windows).

## Coding Rules

- No emojis
- Keep PowerShell compatible with 5.1 (no `using namespace`, no C# 7 in Add-Type)
- All P/Invoke signatures must use explicit `out` variables, not discards
- Wrap all operations in try/catch with SilentlyContinue to prevent hook failures from blocking Claude Code
- Test with multiple concurrent sessions before releasing changes
