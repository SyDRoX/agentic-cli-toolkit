# claude-notify

Desktop notification system for Claude Code on Windows Terminal.

## Architecture

Hooks (cmd.exe) -> notify.ps1 (PowerShell) -> popup.ps1 (WPF)

- `attention.cmd` / `resume.cmd` are thin cmd.exe wrappers required because Claude Code hooks run via cmd.exe on Windows
- `notify.ps1` is the dispatcher: flashes the taskbar, launches/kills popup processes
- `popup.ps1` is a standalone WPF window launched as a separate PowerShell process with `-STA` flag
- `save-hwnd.exe` is a .NET Framework 4 console app compiled from `SaveHwnd.cs`
- `setup.sh` is the user-facing setup script that runs `save-hwnd.exe` and stores results per-session

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

All runtime state is in `~/.claude/hooks/claude-notify/`, keyed by `WT_SESSION`:

- `.hwnd-{session}` - Window handle
- `.tabindex-{session}` - Tab position (1-based)
- `.popup-{session}.pid` - Active popup PID

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
