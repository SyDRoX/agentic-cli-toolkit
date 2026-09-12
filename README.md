# dev-layout (local fork)

One Windows Terminal window, 4 Claude Code tabs, one per repo, maximized on the
left monitor. Each tab reopens its previous conversation.

Adapted from [SyDroX/dev-layout](https://github.com/SyDroX/dev-layout) (MIT, see
`LICENSE`).

| Tab | Repo | Session slot |
|-----|------|--------------|
| 1 | `C:\Repos\ormi-unity` | `devlayout-w1-t1` |
| 2 | `C:\Repos\PotatoSandwich` | `devlayout-w1-t2` |
| 3 | `C:\Repos\WaaaghGamez` | `devlayout-w1-t3` |
| 4 | `C:\Repos\DefendYourCastle3D` | `devlayout-w1-t4` |

## Usage

```powershell
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\DevLayout.ps1"
```

Or `DevLayout.bat` (pin to taskbar), or `Ctrl+Alt+D` after running
`Setup-DevLayoutShortcut.ps1`.

Check what each tab will reopen, without launching anything:

```powershell
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\Test-Resume.ps1"
```

## Parallel-clone layouts

Three extra launchers open one window per game (or one for both) across the
primary checkout and the two parallel clones in `C:\repos2` and `C:\repos3`.
They share `LayoutEngine.ps1`, a generalized form of `DevLayout.ps1`'s logic.

| Script | Window slot | Tabs |
|--------|-------------|------|
| `ClaudePotatoLayout.ps1` | 2 | `C:\Repos\PotatoSandwich`, `C:\repos2\PotatoSandwich2`, `C:\repos3\PotatoSandwich3` |
| `ClaudeOrmiLayout.ps1` | 3 | `C:\Repos\ormi-unity`, `C:\repos2\ormi-unity2`, `C:\repos3\ormi-unity3` |
| `ClaudeBothLayout.ps1` | 4 | all six of the above, PotatoSandwich first |

```powershell
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\ClaudePotatoLayout.ps1"
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\ClaudeOrmiLayout.ps1"
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\ClaudeBothLayout.ps1"
```

Add `-DryRun` to print the `wt.exe` command without launching anything.

Each one also has a `.bat` wrapper (`ClaudePotatoLayout.bat`, `ClaudeOrmiLayout.bat`,
`ClaudeBothLayout.bat`) for taskbar pinning; they forward their arguments, so
`-DryRun` works there too.

## Codex CLI layouts

Matching Codex CLI launchers use the same repository tabs, monitor placement,
and `.bat` wrappers. They use separate window-handle state under
`~/.codex/dev-layout/`, so they can run alongside the Claude layouts.

| Script | Window slot | Tabs |
|--------|-------------|------|
| `CodexPotatoLayout.ps1` | 12 | `PotatoSandwich` primary checkout and two clones |
| `CodexOrmiLayout.ps1` | 13 | `ormi-unity` primary checkout and two clones |
| `CodexBothLayout.ps1` | 14 | all six of the above, PotatoSandwich first |

```powershell
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\CodexPotatoLayout.ps1"
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\CodexOrmiLayout.ps1"
pwsh -ExecutionPolicy Bypass -File "C:\Repos\dev-layout\CodexBothLayout.ps1"
```

The `.bat` counterparts have the same names and can be pinned to the taskbar.
Each tab runs `codex resume --last` in its own repository. Codex filters that
selection by working directory, so it reopens the most recent interactive
Codex conversation for that repo; a repository with no previous conversation
opens a new session automatically.

Each layout owns its own **window slot**, because a session slot is keyed by
`devlayout-w<window>-t<tab>`. `DevLayout.ps1` keeps slot 1, so nothing above
disturbs its four conversations. The flip side is that `ClaudeBothLayout.ps1` tab 1
and `ClaudePotatoLayout.ps1` tab 1 are *different* conversations even though both sit
in `C:\Repos\PotatoSandwich` — pick one launcher per game and stay with it if
you want continuity. Session resume works exactly as described above: the
`SessionStart` hook is keyed off `DEVLAYOUT_WINDOW`/`DEVLAYOUT_TAB`, which the
shared `launch-claude.ps1` sets for these layouts too.

Note that the parallel clones were made without Unity's ignored directories, so
`Library/` is absent and the first Unity launch in each reimports every asset.

## How session resume works

This is the part worth understanding, because it is the reason the setup exists.

Each tab is a **slot**, identified by `devlayout-w<window>-t<tab>`. A slot owns a
deterministic UUID (RFC-4122 v3, MD5 of the slot key), so tab 3 always maps to
the same conversation with no bookkeeping at all.

On top of that, a `SessionStart` hook records whichever session a tab is actually
showing into `~/.claude/dev-layout/.devlayout-session-w1-t<N>`. That means if you
switch conversations with `/resume` inside a tab, the tab reopens *that* one next
time instead of its default. The hook fires at session **start**, not exit, so
this survives a force-close or an OS restart.

    Priority: state file (manual /resume) > deterministic slot UUID > new session

A recorded id is only honoured if its transcript actually exists in that tab's own
project directory (`~/.claude/projects/C--Repos-<name>`), so a stale entry can
never send a tab chasing a conversation from another repo.

If a resume is rejected because the transcript was deleted or is corrupt, the tab
starts a fresh session instead of dying at a prompt, and the hook records the new
id so the next launch resumes it. Self-healing.

## Divergences from upstream

Behavioural, by request:

- **One window, not two.** Upstream opens two windows of 4 tabs each.
- **Per-tab working directories.** Upstream points all 4 tabs of a window at one
  shared workspace root; here every tab gets its own repo.
- **Maximize on the target monitor** instead of Win+Arrow half-screen snapping.
  The `keybd_event` key-simulation code is gone with it.
- **No `--model` flag.** Claude Code picks its own default. Upstream pinned
  `claude-fable-5[1m]` and had extra machinery to remember a per-slot model.
- **No cd-blocking hook.** Upstream installs a PreToolUse hook into every
  workspace to block `cd`, because its Claude sits in a parent directory above
  many repos and a `cd` would lose access to the others. Here each tab is already
  scoped to a single repo, so that rationale does not apply.

Bugs fixed along the way:

- **State directory.** Upstream writes session state into
  `~/.claude/hooks/agentic-cli-notify/`, a directory belonging to the notification
  component. When it is absent, every `Set-Content` fails and
  **nothing ever resumes**. State now lives in `~/.claude/dev-layout/`, created
  by the setup script.
- **agentic-cli-notify is now optional.** Upstream calls its `setup.sh`
  unconditionally and polls 15s for an HWND file; both are skipped when the
  integration is not installed.
- **Malformed slot UUIDs.** Upstream sets the UUID version nibble on `$hash[6]`
  and builds the id with `[guid]::new([byte[]])`, which reads the first three
  fields *little-endian* — so the nibble lands in the wrong place and 3 of 4 slots
  got ids like `...-a13f-...` and `...-0337-...`. Claude Code's `--session-id`
  validation is lenient enough to accept those today (verified), so this was
  cosmetic rather than breaking, but it would break if that validation ever
  tightened. Ids are now formatted big-endian in RFC order.
- **Setup script PowerShell version.** Upstream's `Setup-SessionHook.ps1`
  declares `#Requires -Version 5.1` but uses `ConvertFrom-Json -AsHashtable`,
  which needs PowerShell 6+, and its README tells you to run it with
  `powershell` (5.1), where it fails. Registration now happens in
  `register-session-hook.js`, which also edits only the key it owns instead of
  reformatting the whole settings file, and backs it up first.
- **Non-interactive shortcut setup.** Upstream's `Read-Host` prompt hangs when
  run non-interactively; the desktop shortcut is now a `-Desktop` switch.

## Files

| File | Purpose |
|------|---------|
| `DevLayout.ps1` | Launcher: builds the `wt.exe` command, finds and maximizes the window |
| `launch-claude.ps1` | Per-tab: resolves the slot's session and starts Claude |
| `SessionSlot.ps1` | Shared slot UUID / project path / resume resolution |
| `Test-Resume.ps1` | Dry-run of the resume decision for all 4 tabs |
| `hooks/devlayout-session-save.ps1` | `SessionStart` hook, records the live session id |
| `Setup-DevLayout.ps1` | One-time install (hook + state dir + registration) |
| `register-session-hook.js` | Format-preserving `settings.json` edit |
| `Setup-DevLayoutShortcut.ps1` | Optional `Ctrl+Alt+D` hotkey |
| `DevLayout.bat` | Wrapper for taskbar pinning |
| `LayoutEngine.ps1` | Shared launcher engine used by the three layouts below |
| `agentic-cli-notify/` | Bundled Claude/Codex terminal notification component |
| `ClaudePotatoLayout.ps1` | PotatoSandwich x3 (window slot 2) |
| `ClaudePotatoLayout.bat` | Wrapper for taskbar pinning |
| `ClaudeOrmiLayout.ps1` | ormi-unity x3 (window slot 3) |
| `ClaudeOrmiLayout.bat` | Wrapper for taskbar pinning |
| `ClaudeBothLayout.ps1` | Both games x3 in one window (window slot 4) |
| `ClaudeBothLayout.bat` | Wrapper for taskbar pinning |

## Changing the repos

Edit `$Config.Tabs` in `DevLayout.ps1` and the `$Tabs` list in `Test-Resume.ps1`.

Tab **order is load-bearing**: slot UUIDs derive from tab position, so reordering
the list reassigns which conversation each tab reopens. Adding a 5th tab is safe;
reordering the existing four is not.

## Layout composer

Run `LayoutUI.bat` to open the Python/Tkinter layout composer. Use **Load** to
open a file browser and select any preset JSON, and **Repos...** to add, edit, or remove repository entries. The
catalog is persisted in `repos.json` beside the UI. Select a tab and use **Edit
tab** to change its repository or agent.

## Open LLM CLI context menu

`LLM_ContextMenu_Toggle.ps1` installs a Windows Explorer context menu for opening
an LLM CLI in the selected folder. It provides entries for Anti Gravity, Claude,
Codex, Pi HY4, and Agent, plus a toggle for opening a new Windows Terminal or
appending to the existing one.

Install or switch the terminal behavior with:

```powershell
powershell -ExecutionPolicy Bypass -File .\LLM_ContextMenu_Toggle.ps1 -Mode New
powershell -ExecutionPolicy Bypass -File .\LLM_ContextMenu_Toggle.ps1 -Mode Append
```

The selected folder is passed as the working directory, and the context-menu
entries launch inside Windows Terminal.
