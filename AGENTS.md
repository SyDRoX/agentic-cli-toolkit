# agentic-cli-toolkit

Windows-only tooling that launches agentic CLIs (Claude Code, Codex, pi, Cursor Agent)
across repos in Windows Terminal, keeps per-tab sessions resumable, and raises desktop
notifications when an agent needs input. Upstream: SyDRoX/dev-layout (MIT).

## Components

| Area | Entry point | Notes |
|------|-------------|-------|
| Layout composer UI | `LayoutUI.bat` -> `layout_ui.py` | Python 3 + customtkinter. Edits/launches JSON presets in `custom-layouts/`. Work directories in `repos.json`. Theme tokens in `ui_theme.py`. Last opened preset and recently picked models are stored in `.layout-ui-state.json` beside the script/exe and reopened on the next start. |
| Standalone exe | `Build-LayoutUI.ps1` + `LayoutUI.spec` | PyInstaller onefile to repo root. Exe reads `custom-layouts/`, `repos.json`, `ps1-scripts/`, `styles/` from its own folder; none bundled. |
| Layout launcher | `ps1-scripts/Invoke-CustomLayout.ps1 -ConfigPath <json> [-DryRun]` | One `Invoke-LayoutWindow` call per window. Maps `agent` key to launcher. |
| Layout engine | `ps1-scripts/LayoutEngine.ps1` | Dot-sourced. Opens one WT window, one tab per repo, maximized or snapped left/right on target monitor. Win32 plumbing lives here. |
| Per-agent launchers | `launchers/launch-{claude,codex,pi,agent}.ps1` | Positional args: TabIndex, Label, WindowNum, Model, Effort, ContextWindow, Style. Run inside the tab's working dir. |
| Response styles | `styles/` + `ps1-scripts/ResponseStyle.ps1` | One rules file per style (`ste.md`, `caveman.md`), listed in `styles/styles.json`, shared by Claude, Codex and pi. `ps1-scripts/Install-ResponseStyles.ps1` installs the Claude output styles and the `/style` skill. See "Response styles" below. |
| Skills | `skills/` + `ps1-scripts/Install-Skills.ps1` | Claude only. One folder per skill, copied to `~/.claude/skills`. Ships `/memory-lint`. See "Skills" below. |
| Session resume | `ps1-scripts/SessionSlot.ps1`, `hooks/devlayout-session-save.ps1`, `register-session-hook.js` | Claude only. Install via `ps1-scripts/Setup-DevLayout.ps1`. Dry-run via `ps1-scripts/Test-Resume.ps1`. |
| Notifications | `agentic-cli-notify/` | Taskbar flash + WPF popup per WT tab. Own docs: `agentic-cli-notify/README.md`, `agentic-cli-notify/CLAUDE.md`. |
| `notify` command | `agentic-cli-notify/ps1-scripts/notify-cli.ps1` + `SessionRegistry.ps1` | On PATH after `install.ps1`. `notify <agent> [flags]` sets up notifications for the current tab and registers it; `notify list / close / restore` save, close and reopen every registered tab on its exact conversation; `notify reopen` brings back tabs closed with X. Tab positions are re-read from Windows Terminal (`save-hwnd.exe --locate`), so reorder and moves between windows are followed. Covers `notify`, context-menu and layout tabs. |
| Explorer menu | `ps1-scripts/LLM_ContextMenu_Toggle.ps1` + `LLM_ContextMenu.config.yaml` | "Open LLM CLI here" registry menu. YAML drives entries, toggles, defaults. Re-run script after YAML edits. Each entry launches through `notify`, so the tab is registered. |
| Hotkey shortcut | `ps1-scripts/Setup-DevLayoutShortcut.ps1 [-Preset <name-or-path>] [-Desktop]` | Ctrl+Alt+D Start Menu shortcut. Opens `LayoutUI.bat`, or with `-Preset` launches that layout via `Invoke-CustomLayout.ps1` (no UI). |

## Layout JSON schema

```json
{
  "name": "Main",
  "windows": [
    {
      "name": "label", "windowNum": 102, "targetMonitor": 0, "position": "maximize",
      "tabs": [
        { "title": "T1", "workingDir": "C:\\Repos\\x", "agent": "pi",
          "model": "openrouter/tencent/hy4-preview", "effort": "medium", "contextWindow": "0.25m",
          "style": "ste" }
      ]
    }
  ]
}
```

- `position`: `maximize` (default) | `left` | `right`. Left/right snap the window to that half of `targetMonitor` via Win+Arrow. Not editable in the
  UI yet; the UI preserves it on save.
- `agent`: `claude` | `codex` | `pi` | `cursor` (alias `agent`). Case-insensitive.
- `model`, `effort`, `contextWindow` optional; empty = CLI default. Cursor ignores all three.
- `style` optional: a key from `styles/styles.json` (`ste` | `caveman`), its label, or `off`; empty or absent = the catalog default (`"default":
  true`, currently `ste`). Unknown values warn and launch without a style. Cursor ignores it.
- `effort`: `low|medium|high|xhigh|max`. Claude `--effort`, Codex `model_reasoning_effort`, pi `--thinking`.
- `contextWindow`: Claude only `default[1m]`; Codex `default|0.25m|0.5m|MAX`; pi `default|0.25m|0.5m|1m|MAX`. Pi has no flag, so `launch-pi.ps1`
  writes `modelOverrides.contextWindow` into a per-tab config directory (see below).
- Pi `MAX` means the selected model's catalog window from `~/.pi/agent/models-store.json`. For the OpenAI GPT-5.6 models that catalog value is pi's
  short-context-pricing default (272000), not the provider ceiling, so `MAX` is a no-op there and `1m` is what opts them into the long-context window.
  Verify any change with `pi --list-models <id>`, which prints the effective window.
- Model lists are live: `model_catalog.py` reads Claude `/v1/models` (`ANTHROPIC_API_KEY`, else the Claude Code OAuth token), Codex
  `~/.codex/models_cache.json` and pi `~/.pi/agent/models-store.json`, caches them in `.model-cache.json` beside the script/exe for 24h, and falls
  back to the cache of any age, then to the `CLAUDE_MODELS` / `CODEX_MODELS` / `PI_MODELS` constants in `layout_ui.py`. The UI starts on the cache,
  refreshes in a background thread, and has a "Refresh models" button that bypasses the TTL. The model cell dropdown shows 10 entries: the last 5
  models picked per agent (`recentModels` in `.layout-ui-state.json`), then catalog order (Claude newest first, Codex by priority, pi `anthropic*`
  then `openai*` providers first). Typing filters the full catalog (every word must match, prefix matches first); Down opens the filtered list.
  Effort/context lists are still constants. Tests: `python -m unittest discover -s tests`.

## Invariants (do not break)

- **`windowNum` is a session namespace.** Slot UUID = MD5 v3 of `devlayout-w<WindowNum>-t<TabIndex>`. UI assigns from `SLOT_START = 100`, persists in
  preset. Never renumber a preset in use; never share a number between presets.
- **Tab order is load-bearing** for same reason. Reordering tabs remaps conversations.
- **Claude resume priority:** state file `~/.claude/dev-layout/.devlayout-session-w<N>-t<M>` > deterministic slot UUID > fresh session. Missing or
  corrupt transcript = fresh. Hook no-ops unless `DEVLAYOUT_WINDOW`/`DEVLAYOUT_TAB` env set.
- **Codex/pi/Cursor resume is per working dir** (`codex resume --last`, `pi --continue`, `agent --continue --workspace`). No slot logic.
- **Pi context window is a per-tab config overlay.** pi reads `modelOverrides` only from `<config dir>/models.json`, and that file is global, so
  writing it from every tab makes the last tab launched win for all of them. `launch-pi.ps1` therefore points `PI_CODING_AGENT_DIR` at
  `~/.pi/devlayout/w<N>-t<M>`, an overlay rebuilt on every launch that holds its own `models.json` (the global one, if any, with the tab's override
  merged in, so custom providers survive) and shares every other entry of `~/.pi/agent` - directories (`sessions`, `extensions`, `skills`, ...) as
  NTFS junctions, files (`auth.json`, `settings.json`, `AGENTS.md`, ...) as hard links. Never share by a fixed list: pi reads more from its config
  directory than any list here would keep up with. Hard links are safe because pi rewrites those files in place (`writeFileSync`), never through a
  temp-file rename; if that changes upstream, the overlay would go stale and the shared files must be junctioned or copied instead. `trust.json` is
  seeded as `{}` in the global directory so a `/trust` decision persists there. Sessions stay global through the `sessions` junction: pi stores a
  session in `<config dir>\sessions\--<cwd with separators replaced>--`, so junctioning that directory keeps one store and keeps `pi --continue` per
  working dir. Never set `PI_CODING_AGENT_SESSION_DIR` instead - it names the exact session directory, which drops pi's per-working-dir split and
  makes every tab resume the session written last in any repo. Tabs on `contextWindow: "default"`, or whose value equals the model's catalog window,
  get no overlay and no env vars. Never write `~/.pi/agent/models.json` from a launcher.
- Launchers clear inherited `CLAUDECODE` env to avoid nested-session error.
- `Invoke-CustomLayout.ps1` strips agent-session env (`CLAUDE_CODE_CHILD_SESSION`, `NO_COLOR`, ...) before calling wt.exe, because wt.exe passes the
  caller's env to new tabs. Launched from inside Claude Code, tabs otherwise lose color and transcript saving. Vars set at User/Machine scope are
  kept.
- Never put `;` inside a tab command: wt.exe splits on it as a tab separator.
- `register-session-hook.js` edits only its own key in `~/.claude/settings.json`. Do not replace with a PowerShell JSON round-trip (needs PS 6+,
  reformats file).
- Notification state keyed by `WT_SESSION`. Hooks outside Windows Terminal are ignored.
- **Launchers register their tab** through the installed `SessionRegistry.ps1` (skipped when notify is not installed) and unregister in `finally`.
  Restore reruns the launcher with its original seven arguments, so `windowNum` and tab-order rules above still decide the Claude conversation. Codex,
  pi and Cursor launchers take an exact conversation from `AGENTIC_RESUME_ID` and fall back to their per-working-dir resume when it is rejected; they
  clear the variable before starting the agent.

## Conventions

- PowerShell must stay 5.1 compatible: no `using namespace`, no `?.`, no `-AsHashtable`, no C# 7 in `Add-Type`. Keep `#Requires -Version 5.1`.
- Wrap hook code in try/catch; hooks must never block the agent CLI.
- No emojis in code or scripts.
- Scripts resolve paths from `$PSScriptRoot` / `$MyInvocation`; never hardcode user or checkout paths.
- Non-interactive scripts: no `Read-Host`; take switches instead.
- Python: `layout_ui.py` single-file UI (`model_catalog.py` stays UI-free); colors only via `ui_theme.resolve_color()`; unknown role raises.
- Gitignored runtime output: `LayoutUI.exe`, `build/`, `__pycache__/`, `.model-cache.json`, user presets in `custom-layouts/` (except `Main.json`,
  `Mixed Example.json`), notify state files (`.hwnd-*`, `.tabindex-*`, `.popup-*.pid`, `.slots/`, `.sessions/`, `save-hwnd.exe`).

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
powershell -NoProfile -ExecutionPolicy Bypass -File .\agentic-cli-notify\ps1-scripts\Test-NotifyCli.ps1

# Launch an agent with notifications in the current tab; close / reopen all agent tabs
notify claude --dangerously-skip-permissions
notify close
notify restore

# Explorer context menu
powershell -ExecutionPolicy Bypass -File .\ps1-scripts\LLM_ContextMenu_Toggle.ps1 -Mode New

# Check the effective pi context window of one tab's overlay
$env:PI_CODING_AGENT_DIR = "$env:USERPROFILE\.pi\devlayout\w102-t1"; pi --list-models gpt-5.6-luna
```

## Bundled Pi theme

- `themes/pi/sydrox-orange-matrix.json` is the canonical bundled Pi theme; it is
  separate from the composer's `ui_theme.py`.
- `ps1-scripts/Install-PiTheme.ps1 [-AgentDir <path>] [-WhatIf] [-Force]` copies it
  into the global Pi agent directory by default. It never edits settings, skips
  identical files, and requires `-Force` for a differing existing theme.
- Pi overlays already share the global themes directory. Do not add theme writes
  to the launcher or install separately into overlay slots.
- Regression: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PiTheme.ps1`.
  Manual acceptance: select the theme in ordinary Pi and a toolkit overlay tab.

## Response styles

- `styles/<key>.md` holds the rules as plain Markdown with no agent-specific frontmatter. `styles/styles.json` maps each key to its label, file and
  description; one entry has `"default": true` (`ste`), used for an empty layout `style` and outside the launchers. Add a style by adding both; the
  composer's Style column, the launchers, the installer and the pi `/style` command all read the catalog.
- **Claude:** `launch-claude.ps1` passes `--settings <state dir>\.devlayout-style-<key>.json` holding only `outputStyle`, which overrides the user's
  global value for that tab. This needs the output style installed as `~/.claude/output-styles/agentic-<key>.md` (`Install-ResponseStyles.ps1`);
  without it the launcher warns and falls back to `--append-system-prompt-file`. The settings go in a file because Windows PowerShell 5.1 strips
  double quotes from inline JSON arguments. The launcher also sets `CAVEMAN_DEFAULT_MODE` (`full` for `caveman`, else `off`) so the third-party
  caveman plugin's SessionStart hook does not inject the other style, exports `DEVLAYOUT_STYLE`, and deletes the tab's
  `~/.claude/style-sessions/<session id>` flag.
- **Claude records the system prompt per conversation** (`--system-prompt-snapshot`, on by default). On a resumed conversation a changed style reaches
  the model as a later instruction block, not as a new system prompt. Do not pass `--system-prompt-snapshot off` to force it: that re-renders the
  prompt on every request.
- **Claude `/style` skill** (`styles/claude-skill/`, installed to `~/.claude/skills/style/`): `Switch-ResponseStyle.ps1` edits only the `outputStyle`
  value in `settings.json` by text replacement (same reason as `register-session-hook.js`), touches the caveman plugin config only when that plugin is
  present, writes `~/.claude/.style-mode` and `~/.claude/style-sessions/<session id>`, and prints the rules for the running session to adopt. Inside a
  running conversation this is an instruction, not a system prompt change.
- **Codex:** `launch-codex.ps1` passes `-c developer_instructions=<TOML multi-line literal>` built by `ConvertTo-CodexInstructionArg`, which turns
  double quotes into single ones and shortens runs of three or more quotes, or `developer_instructions=''` for `off`. Launch-time only; relaunch the
  tab to change it. The installer writes the default style as a managed block at the top of `~/.codex/config.toml` (`Set-CodexStyleBlock`); it throws
  if `developer_instructions` is already set outside the block.
- **pi:** the installer writes a shim `~/.pi/agent/extensions/agentic-cli-style.ts` that imports `styles\pi-extension\agentic-cli-style.ts` from the
  checkout, so a bare `pi` gets the default. `launch-pi.ps1` sets `AGENTIC_STYLES_DIR` and `AGENTIC_STYLE` (`off` for no style; unset or empty =
  catalog default) and passes `--extension` only when the shim is absent. The
  extension writes the rules into `systemPromptOptions.sections.response_style` in `before_agent_start`, registers `/style [key|off]`, and shows the
  label in the footer. It edits `sections` rather than returning `systemPrompt` so pi patches one section and keeps the cached prefix. Never copy
  the extension itself into `~/.pi/agent/extensions`, and never pass `--extension` while the shim exists: `/style` would register twice.
- `Install-ResponseStyles.ps1 [-ClaudeDir <path>] [-CodexDir <path>] [-PiDir <path>] [-WhatIf] [-Force]` never edits Claude settings, skips Codex or
  pi when their directory is missing, skips identical files, requires `-Force` for a differing
  file, and warns when another output style file already uses the same `name`.
- Statuslines: Claude Code passes the session's style as `output_style.name` (`ASD-STE100` / `Caveman`) in the statusline JSON; a `/style` switch
  inside a session is visible only through `~/.claude/style-sessions/<session id>`.
- Tabs opened through `notify` or the Explorer menu do not pass a style; Claude uses its global `outputStyle`, Codex the `config.toml` block and pi
  the shim's catalog default.
- Regression: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ResponseStyles.ps1`.

## Working rules

- `rules/agent-rules.md` is plain Markdown with no agent-specific syntax and no personal or employer details; the repository is public.
- `ps1-scripts/Install-AgentRules.ps1 [-ClaudeDir <path>] [-CodexDir <path>] [-PiDir <path>] [-WhatIf] [-Remove]` writes it as a managed block
  (HTML comment markers) into `<ClaudeDir>\CLAUDE.md`, `<CodexDir>\AGENTS.md` and `<PiDir>\AGENTS.md`. It only ever replaces its own block, keeps
  the file's line endings, creates a missing file, skips a missing agent directory, and throws on unbalanced markers. No `-Force`: the block is
  owned by the installer.
- pi overlays hard-link `AGENTS.md` from the global agent directory, so layout tabs get the rules with no launcher change. An `AGENTS.override.md`
  in the pi agent directory replaces `AGENTS.md`; the installer warns.
- Regression: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AgentRules.ps1`.

## Skills

- `skills/<name>/` is one Claude Code skill: a `SKILL.md` plus the files it runs. Flat folders only; the installer does not copy subfolders. No
  personal or employer details: per-user data such as repository aliases stays in the user's own config, never in the skill.
- `ps1-scripts/Install-Skills.ps1 [-ClaudeDir <path>] [-Force] [-WhatIf] [-Remove]` copies every skill folder to `<ClaudeDir>/skills/<name>` with LF
  line endings. A differing destination file stops the run before any write unless `-Force` is given. `-Remove` deletes only shipped files, and a
  skill folder only when that leaves it empty. The `/style` skill is not here; `Install-ResponseStyles.ps1` builds it.
- `skills/memory-lint/memory_lint.py` only reads and uses the standard library. It resolves a `<alias> ... #N` pull request claim to the nearest
  alias before the number, and takes the claim text from the previous PR reference or sentence break up to the next PR reference, so a status word
  for one PR does not count for its neighbour.
- Regression: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Skills.ps1` and `python -m unittest discover -s tests`.

## Adding a new agent

1. Add `launchers/launch-<agent>.ps1` with the seven positional params; resume per working dir.
2. Add key to `$AgentMap` in `ps1-scripts/Invoke-CustomLayout.ps1`.
3. Add to `AGENTS`, model/effort/context tables in `layout_ui.py`.
4. Add notification adapter in `agentic-cli-notify/` (see its `CLAUDE.md`); `notify.ps1 -Agent` value is only a popup title.
5. Update `README.md` and this file.
