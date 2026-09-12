# agentic-cli-notify

Desktop notifications for Claude Code and Codex CLI on Windows Terminal.

When your assistant finishes a task and needs your input, you get:

- **Taskbar flash** on the correct Windows Terminal window
- **WPF popup** (dark theme, slide-in animation) in the bottom-right corner
- **Click to switch** - focuses the right window and activates the right tab

Supports multiple concurrent Claude Code sessions across multiple Windows Terminal windows without interference.

![popup example](https://img.shields.io/badge/popup-dark_theme_|_orange_accent-1a1a2e?style=for-the-badge&labelColor=f0883e)

## How It Works

Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) trigger notifications:

| Hook | Fires When | Action |
|------|-----------|--------|
| `Stop` | Claude finishes and waits for input | Flash taskbar + show popup |
| `UserPromptSubmit` | You send a message | Stop flash + dismiss popup |

Each session is isolated by its `WT_SESSION` environment variable, so notifications always target the correct window and tab.

```
Stop hook -> attention.cmd -> notify.ps1 attention -> FlashWindowEx + WPF popup
UserPromptSubmit hook -> resume.cmd -> notify.ps1 resume -> StopFlash + kill popup
```

When multiple sessions need attention simultaneously, popups stack vertically instead of overlapping.

## Requirements

- Windows 10/11
- [Windows Terminal](https://github.com/microsoft/terminal)
- Claude Code CLI or Codex CLI with lifecycle hook support
- PowerShell 5.1 (included with Windows)
- .NET Framework 4 (included with Windows, needed to compile `save-hwnd.exe`)

## Installation

### Codex CLI

From this repository, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ps1-scripts\install-codex.ps1
```

This installs the shared notification scripts into
`~/.claude/hooks/agentic-cli-notify/` (the same location used by DevLayout), compiles
`save-hwnd.exe`, and adds `Stop` and `UserPromptSubmit` commands to
`$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json` when `CODEX_HOME` is unset.
Existing hooks are preserved, changed settings are backed up, and rerunning
the installer does not duplicate hooks. Claude's hook registration is unchanged.

In Codex, open `/hooks` and review/trust the two `codex-hook.ps1` hooks. If the
current session does not list them, restart/resume the CLI first. If hooks are
disabled, set `hooks = true` under `[features]` in your Codex `config.toml`.
See the [official Codex hooks documentation](https://learn.chatgpt.com/docs/hooks).

Then configure each tab **while that tab and its Windows Terminal window are
focused** (Git Bash is required for this setup command):

```powershell
& 'C:\Program Files\Git\bin\bash.exe' "$env:USERPROFILE/.claude/hooks/agentic-cli-notify/setup.sh"
```

The popup says **Codex**, flashes the saved terminal window, and uses the same
click-to-tab and multi-monitor behavior as Claude. Sending a new prompt dismisses
that tab's popup. Re-run tab setup after restarting Terminal or reordering tabs.
This integration uses lifecycle hooks, so no `notify` entry in `config.toml` is
needed. It handles completed turns and prompt submission; approval requests are
not covered. Hooks outside Windows Terminal are ignored.

Run the isolated regression checks with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ps1-scripts\Test-CodexHooks.ps1
```

`Test-PopupSessions.ps1` additionally shows real Codex test popups on every
monitor and checks that two concurrent sessions dismiss independently. It uses
temporary state and invisible test windows; it does not change live tab mappings.

To uninstall Codex integration, remove only the `codex-hook.ps1` handlers from
`hooks.json`. Keep the shared scripts if Claude Code still uses them.

### Claude Code (when used standalone)

### 1. Clone and install

```bash
git clone https://github.com/SyDRoX/dev-layout.git
cd dev-layout/agentic-cli-notify
bash install.sh
```

This copies scripts to `~/.claude/hooks/agentic-cli-notify/` and compiles `save-hwnd.exe`.

### 2. Register hooks

Add to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "C:\\Users\\YOUR_USERNAME\\.claude\\hooks\\agentic-cli-notify\\attention.cmd",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "C:\\Users\\YOUR_USERNAME\\.claude\\hooks\\agentic-cli-notify\\resume.cmd",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Replace `YOUR_USERNAME` with your Windows username.

### 3. Set up each tab

For **every** Claude Code tab, while focused on the correct Windows Terminal window:

```bash
bash ~/.claude/hooks/agentic-cli-notify/setup.sh
```

This captures the window handle (HWND) and tab position so notifications can target the right window and switch to the right tab.

**Re-run setup.sh after:** WT restart, tab reorder, or adding/removing tabs.

## File Structure

```
agentic-cli-notify/
  attention.cmd      # Stop hook wrapper (cmd.exe -> PowerShell)
  resume.cmd         # UserPromptSubmit hook wrapper
  ps1-scripts/       # PowerShell notification, installer, and test scripts
    notify.ps1       # Main logic: flash window, launch/kill popup
    popup.ps1        # WPF popup: dark theme, click-to-switch, stacking
    codex-hook.ps1   # Codex lifecycle hook adapter
  SaveHwnd.cs        # C# source: captures foreground HWND + tab index
  save-hwnd.exe      # Compiled from SaveHwnd.cs (not in git, built by install)
  setup.sh           # Per-tab setup: captures window handle + tab position
  install.sh         # Full installer (copy + compile + instructions)
  build.cmd          # Compile save-hwnd.exe from SaveHwnd.cs
```

### Runtime state files (generated, gitignored)

```
.hwnd-{WT_SESSION}          # Saved window handle for this session
.tabindex-{WT_SESSION}      # Saved tab index (1-based) for this session
.popup-{WT_SESSION}.pid     # Active popup PID (for stacking + cleanup)
```

## Technical Details

### Why is setup manual?

Windows Terminal uses ConPTY, which means:

- `GetConsoleWindow()` returns 0 from hook subprocesses
- All WT windows share the same UI thread, so you can't distinguish by thread ID
- `GetForegroundWindow()` is unreliable from hook subprocesses (timing issues)
- Tab names change dynamically, so name-based matching is fragile

The only reliable approach is capturing the window handle while the user is focused on the correct window (`setup.sh` does this via `save-hwnd.exe`).

### Window focusing

Bringing a background window to the foreground on Windows requires jumping through hoops:

1. `SetWindowPos(HWND_TOPMOST)` then `SetWindowPos(HWND_NOTOPMOST)` - forces the window above others without keeping it always-on-top
2. `AttachThreadInput` - attaches the popup's thread to the foreground window's thread to gain foreground privilege
3. `SetForegroundWindow` - now works because we have the privilege
4. `SendKeys Ctrl+Alt+N` - switches to the correct WT tab (N = tab index 1-9)

### Multi-session isolation

Each Claude Code tab has a unique `WT_SESSION` environment variable (inherited by child processes). All state files are keyed by this value, so sessions never interfere with each other.

## Troubleshooting

**No popup appears:**
- Run `setup.sh` again from the affected tab
- Check that hooks are registered in `~/.claude/settings.json`
- Verify `save-hwnd.exe` exists in `~/.claude/hooks/agentic-cli-notify/`

**Popup appears but wrong window focuses:**
- Re-run `setup.sh` from the correct tab while focused on the correct WT window
- If you rearranged tabs since setup, run `setup.sh` again

**Popup appears but wrong tab activates:**
- Tab index is position-based (1-9). Re-run `setup.sh` after any tab reorder.

**Crash log:**
- Check `~/.claude/hooks/agentic-cli-notify/popup-crash.log`

## License

MIT
