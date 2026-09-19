# agentic-cli-toolkit

Windows tooling for orchestrating agentic CLIs across repositories, Windows
Terminal sessions, layouts, and notifications.

![agentic-cli-toolkit demo](https://github.com/user-attachments/assets/7873ef4d-c73b-42a6-9720-6af570691389)

## Layout composer

Run `LayoutUI.bat` to open the layout composer. It creates and launches JSON
presets with multiple terminal windows, repositories, and agents (Claude, Codex,
Pi HY4, and Cursor Agent). The UI follows the Windows light/dark setting detected
at launch; the batch file installs `requirements.txt` on first run.

Use **Load** to browse for and open any preset JSON file. The repository catalog
is managed through **Repos...** and persisted in `repos.json`. Existing tabs can
be changed with **Edit tab**.

### Standalone executable

`Build-LayoutUI.ps1` produces a single-file `LayoutUI.exe` in the repo root:

```powershell
.\Build-LayoutUI.ps1                 # add -Clean after changing LayoutUI.spec
```

The exe reads `custom-layouts\`, `repos.json` and `ps1-scripts\` from its own
folder, so keep it beside them - none of those are bundled into it.

Launch a layout from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\Invoke-CustomLayout.ps1 `
  -ConfigPath .\custom-layouts\Main.json -DryRun
```

Remove `-DryRun` to launch Windows Terminal. Window slot numbers are persisted
in presets because they identify the session namespace used for resume.

## Session resume

The toolkit gives each window/tab position a deterministic session slot and
stores manual resume changes under `~/.claude/dev-layout/`. The Claude launcher
uses the recorded session when available, falls back to the deterministic slot,
and starts a fresh session if a transcript is missing or corrupt.

Install the session hook once:

```powershell
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\Setup-DevLayout.ps1
```

## agentic-cli-notify

The former `claude-notify` project is now bundled under `agentic-cli-notify/`. It
provides taskbar flashing and clickable WPF notifications for Claude Code and
Codex CLI sessions, isolated by `WT_SESSION`.

Install Claude/Codex notification hooks from this checkout:

```powershell
# Claude Code notification files and hook registration guidance
powershell -NoProfile -ExecutionPolicy Bypass -File .\agentic-cli-notify\install.ps1

# Codex hook installation and registration
powershell -ExecutionPolicy Bypass -File .\agentic-cli-notify\ps1-scripts\install-codex.ps1
```

Run `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooksgentic-cli-notify\setup.ps1"` from each focused
Windows Terminal tab after installation. Re-run it after restarting Terminal or
reordering tabs.

## Explorer context menu

`LLM_ContextMenu_Toggle.ps1` installs an Explorer menu named **Open LLM CLI
here**. It opens the configured CLI in the selected folder, with toggles for a
new/existing Terminal window and a standard/administrator Terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\LLM_ContextMenu_Toggle.ps1 -Mode New
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\LLM_ContextMenu_Toggle.ps1 -Mode Append -Elevation Admin
```

Edit `ps1-scripts/LLM_ContextMenu.config.yaml` to add, remove, rename, or
reorder CLI commands. The same file controls whether the terminal-mode and
elevation toggles are shown and supplies their initial defaults. Re-run the
script after editing it; removed entries are also removed from Explorer.
Pass `-ConfigPath` to use a YAML file elsewhere; that path is preserved by the
installed toggle commands.

The script stores its own resolved path and the YAML path in the registry, so
it does not depend on a particular username or checkout location. Selecting
the administrator option causes Windows to show a UAC prompt when a CLI is
opened.

## Repository contents

| Path | Purpose |
|------|---------|
| `LayoutUI.bat` / `layout_ui.py` | Layout composer UI |
| `ui_theme.py` | Brand tokens, OS light/dark resolution |
| `Build-LayoutUI.ps1` / `LayoutUI.spec` | Single-file exe build |
| `ps1-scripts/` | Main PowerShell scripts |
| `ps1-scripts/Invoke-CustomLayout.ps1` | Launches a JSON layout |
| `ps1-scripts/LayoutEngine.ps1` | Windows Terminal layout engine |
| `ps1-scripts/SessionSlot.ps1` | Deterministic session-slot and resume logic |
| `launchers/` | Per-agent tab launchers |
| `agentic-cli-notify/` | Bundled multi-agent notification component |
| `ps1-scripts/LLM_ContextMenu_Toggle.ps1` | Explorer integration |
| `ps1-scripts/LLM_ContextMenu.config.yaml` | Explorer menu CLI options and defaults |
| `custom-layouts/` | Example layout presets |
| `repos.json` | Editable repository catalog |

Adapted from [SyDroX/dev-layout](https://github.com/SyDroX/dev-layout) under
the MIT license.
