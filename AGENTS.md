# agentic-cli-toolkit

Windows-only tooling that launches agentic CLIs (Claude Code, Codex, pi, Cursor Agent)
across repos in Windows Terminal, keeps per-tab sessions resumable, and raises desktop
notifications when an agent needs input. Upstream: SyDroX/dev-layout (MIT).

## Components

| Area | Entry point | Notes |
|------|-------------|-------|
| Layout composer UI | `LayoutUI.bat` -> `layout_ui.py` | Python 3 + customtkinter. Edits/launches JSON presets in `custom-layouts/`. Work directories in `repos.json`. Theme tokens in `ui_theme.py`. |
| Standalone exe | `Build-LayoutUI.ps1` + `LayoutUI.spec` | PyInstaller onefile to repo root. Exe reads `custom-layouts/`, `repos.json`, `ps1-scripts/` from its own folder; none bundled. |
| Layout launcher | `ps1-scripts/Invoke-CustomLayout.ps1 -ConfigPath <json> [-DryRun]` | One `Invoke-LayoutWindow` call per window. Maps `agent` key to launcher. |
| Layout engine | `ps1-scripts/LayoutEngine.ps1` | Dot-sourced. Opens one WT window, one tab per repo, maximized on target monitor. Win32 plumbing lives here. |
| Per-agent launchers | `launchers/launch-{claude,codex,pi,agent}.ps1` | Positional args: TabIndex, Label, WindowNum, Model, Effort, ContextWindow. Run inside the tab's working dir. |
| Session resume | `ps1-scripts/SessionSlot.ps1`, `hooks/devlayout-session-save.ps1`, `register-session-hook.js` | Claude only. Install via `ps1-scripts/Setup-DevLayout.ps1`. Dry-run via `ps1-scripts/Test-Resume.ps1`. |
| Notifications | `agentic-cli-notify/` | Taskbar flash + WPF popup per WT tab. Own docs: `agentic-cli-notify/README.md`, `agentic-cli-notify/CLAUDE.md`. |
| Explorer menu | `ps1-scripts/LLM_ContextMenu_Toggle.ps1` + `LLM_ContextMenu.config.yaml` | "Open LLM CLI here" registry menu. YAML drives entries, toggles, defaults. Re-run script after YAML edits. |
| Hotkey shortcut | `ps1-scripts/Setup-DevLayoutShortcut.ps1 [-Desktop]` | Ctrl+Alt+D Start Menu shortcut to `LayoutUI.bat`. |

## Layout JSON schema

```json
{
  "name": "Main",
  "windows": [
    {
      "name": "label", "windowNum": 102, "targetMonitor": 0,
      "tabs": [
        { "title": "T1", "workingDir": "C:\\Repos\\x", "agent": "pi",
          "model": "openrouter/tencent/hy4-preview", "effort": "medium", "contextWindow": "0.25m" }
      ]
    }
  ]
}
```

- `agent`: `claude` | `codex` | `pi` | `cursor` (alias `agent`). Case-insensitive.
- `model`, `effort`, `contextWindow` optional; empty = CLI default. Cursor ignores all three.
- `effort`: `low|medium|high|xhigh|max`. Claude `--effort`, Codex `model_reasoning_effort`, pi `--thinking`.
- `contextWindow`: Claude only `default[1m]`; Codex/pi `default|0.25m|0.5m|MAX`. Pi has no flag, so `launch-pi.ps1` writes `modelOverrides.contextWindow` into `~/.pi/agent/models.json`.
- Model/effort/context option lists live in `layout_ui.py` constants (`CLAUDE_MODELS`, `CODEX_MODELS`, `PI_MODELS`, ...).

## Invariants (do not break)

- **`windowNum` is a session namespace.** Slot UUID = MD5 v3 of `devlayout-w<WindowNum>-t<TabIndex>`. UI assigns from `SLOT_START = 100`, persists in preset. Never renumber a preset in use; never share a number between presets.
- **Tab order is load-bearing** for same reason. Reordering tabs remaps conversations.
- **Claude resume priority:** state file `~/.claude/dev-layout/.devlayout-session-w<N>-t<M>` > deterministic slot UUID > fresh session. Missing or corrupt transcript = fresh. Hook no-ops unless `DEVLAYOUT_WINDOW`/`DEVLAYOUT_TAB` env set.
- **Codex/pi/Cursor resume is per working dir** (`codex resume --last`, `pi --continue`, `agent --continue --workspace`). No slot logic.
- Launchers clear inherited `CLAUDECODE` env to avoid nested-session error.
- `register-session-hook.js` edits only its own key in `~/.claude/settings.json`. Do not replace with a PowerShell JSON round-trip (needs PS 6+, reformats file).
- Notification state keyed by `WT_SESSION`. Hooks outside Windows Terminal are ignored.

## Conventions

- PowerShell must stay 5.1 compatible: no `using namespace`, no `?.`, no `-AsHashtable`, no C# 7 in `Add-Type`. Keep `#Requires -Version 5.1`.
- Wrap hook code in try/catch; hooks must never block the agent CLI.
- No emojis in code or scripts.
- Scripts resolve paths from `$PSScriptRoot` / `$MyInvocation`; never hardcode user or checkout paths.
- Non-interactive scripts: no `Read-Host`; take switches instead.
- Python: `layout_ui.py` single-file UI; colors only via `ui_theme.resolve_color()`; unknown role raises.
- Gitignored runtime output: `LayoutUI.exe`, `build/`, `__pycache__/`, user presets in `custom-layouts/` (except `Main.json`, `Mixed Example.json`), notify state files (`.hwnd-*`, `.tabindex-*`, `.popup-*.pid`, `.slots/`, `save-hwnd.exe`).

## Common commands

```powershell
# Dry-run a preset (prints planned launches)
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\Invoke-CustomLayout.ps1 -ConfigPath .\custom-layouts\Main.json -DryRun

# Build exe (add -Clean after spec/dependency change)
.\Build-LayoutUI.ps1

# Install Claude session-resume hook
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\Setup-DevLayout.ps1

# Install notifications (all detected agents), then per-tab setup
powershell -NoProfile -ExecutionPolicy Bypass -File .\agentic-cli-notify\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\agentic-cli-notify\setup.ps1"

# Notification regression tests
powershell -NoProfile -ExecutionPolicy Bypass -File .\agentic-cli-notify\ps1-scripts\Test-CodexHooks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\agentic-cli-notify\ps1-scripts\Test-PopupSessions.ps1

# Explorer context menu
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\LLM_ContextMenu_Toggle.ps1 -Mode New
```

## Adding a new agent

1. Add `launchers/launch-<agent>.ps1` with the six positional params; resume per working dir.
2. Add key to `$AgentMap` in `ps1-scripts/Invoke-CustomLayout.ps1`.
3. Add to `AGENTS`, model/effort/context tables in `layout_ui.py`.
4. Add notification adapter in `agentic-cli-notify/` (see its `CLAUDE.md`); `notify.ps1 -Agent` value is only a popup title.
5. Update `README.md` and this file.
