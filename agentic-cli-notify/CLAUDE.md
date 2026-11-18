# agentic-cli-notify

Desktop notification system for Claude Code on Windows Terminal.

## Architecture

Hooks (cmd.exe) -> notify.ps1 (PowerShell) -> popup.ps1 (WPF)

- `attention.cmd` / `resume.cmd` are thin cmd.exe wrappers required because Claude Code hooks run via cmd.exe on Windows
- Every agent maps onto the same two actions (`attention`, `resume`) through its own adapter:
  - Claude Code: `attention.cmd` / `resume.cmd` from `~/.claude/settings.json`. `notify.ps1` reads the hook JSON from stdin (Claude only). A finished
    background agent fires `UserPromptSubmit` with a `<task-notification>` prompt while the user is in another tab, so `resume` skips the hwnd/tab
    re-capture for it. `Stop` also fires when a turn ends with async agents still running, so `attention` stays silent while any transcript
    `"isAsync":true` agentId has no matching `<task-id>` notification, or its latest one carries the interim "background work of its own still
    running" note (the agent notifies again when that work ends). Background Bash is not counted: a server that never exits would mute every later
    Stop. Unattended sessions (`CLAUDE_CODE_SESSION_ATTENDED=0`, e.g. `claude -p` launched from a tab) exit at once: they inherit the tab's
    `WT_SESSION`, so they would raise popups for it and re-capture the wrong tab.
  - Codex: `codex-hook.ps1` from `$CODEX_HOME/hooks.json` (event read from the stdin payload)
  - Cursor Agent: `cursor-hook.ps1` from `~/.cursor/hooks.json`, events `stop` and `beforeSubmitPrompt`; the event is passed as `-Action` because the
    payload field name differs between Cursor versions
  - pi: `pi-extension/agentic-cli-notify.ts`, installed to `~/.pi/agent/extensions/`, on `agent_settled` / `ui_prompt_start` (attention),
    `session_start` / `before_agent_start` (resume) and `ui_prompt_end` (dismiss). Attention is gated on a running turn: the extension arms on
    `before_agent_start` or `agent_start` (runs an extension starts skip `before_agent_start`) and disarms on `agent_settled`, so pi's own startup
    dialogs (project trust, pickers) raise nothing. A turn the user aborted with escape sends `resume`, not `attention` - `agent_settled` carries no
    outcome, so the stop reason is read from `message_end`. Spawn the notifier without `detached`: DETACHED_PROCESS gives powershell.exe no console and
    it exits 0 without running the script. Use `windowsHide` so the child gets its own hidden console and does not rename the WT tab. Notifier runs are
    queued one at a time so a quick `dismiss` cannot overtake the `attention` it answers.
- `dismiss` is `resume` without re-capturing the selected tab: use it when the event does not prove the user is in the tab (a dialog that timed out).
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
- `.popup-{session}.pid` - One `<pid>|<start ticks>` line per popup, written by `notify.ps1` when it starts the popup. A pid is only killed when its
  start time still matches, because Windows reuses pids.
- `.sessions/` - Tab registry and close/restore snapshots; see "notify command and session registry" below
- `.slots/{screen}-{pid}.slot` - Stack slot claim per live popup, holding `<claimTicks>|<height>`. Popups stack by claim order and reflow down when a
  lower popup closes; claims of dead processes are purged on the next poll.

## notify command and session registry

- `ps1-scripts/notify-cli.ps1` installs as `bin\notify.ps1` (own folder on PATH; the flat `notify.ps1` is the hook dispatcher). No `param()` block
  on purpose: agent flags such as `-c` / `-r` must reach the agent, not bind to the script.
- `ps1-scripts/SessionRegistry.ps1` is dot-sourced by the command and by the four layout launchers (from the installed copy, guarded by
  `Test-Path`). It must never throw: a registry failure may not stop an agent from launching.
- Record `.sessions/{session}.json` is written at launch and deleted when the agent exits. Liveness = shell pid plus start time; dead records are
  pruned on read.
- Hooks never rewrite the record. `notify.ps1` writes `.sessions/{session}.state` (`busy` on resume/dismiss, `idle` on attention or `resume -Idle`)
  and `.sessions/{session}.conv` (`<Agent>|<id>`), and only for sessions that have a record. The conversation id is `-ConversationId` from the
  adapter, or `session_id` from Claude's hook JSON. A `.conv` written by another agent than the record names is ignored.
- `notify close` closes a tab by terminating the process Windows Terminal started for it with exit code 0, then its descendants. Exit code 0 plus
  no surviving console client is what makes WT drop the tab without a "process exited" pane or a close-all-tabs dialog. Do not switch to
  `WM_CLOSE`: it takes unregistered tabs with it and raises the dialog. Parent links are checked against creation time, because Windows reuses pids.
- `notify restore` opens one `wt -w new` per saved window; each tab runs `notify.ps1 __resume <snapshot> <window> <tab> <token>` and waits for
  `.sessions/restore-<token>-<window>.hwnd`, which the restore command writes once the window exists. Layout tabs rerun their launcher with the
  original six arguments and get the exact conversation in `AGENTIC_RESUME_ID` (Codex, pi, Cursor; Claude uses its slot).
- Tab positions are re-read, not trusted: `save-hwnd.exe --locate <session>:<pid> ...` attaches to each tab's console, sets a marker title,
  finds the marker among the TabItems of every WT window, restores the title and rewrites `.hwnd-` / `.tabindex-` / `.tabname-`. This is the
  only way to find a tab that is not selected, and it survives reorder and a move to another window (a UI Automation `RuntimeId` does not:
  WT builds a new tab object in the target window). Callers: `notify.ps1` before a popup (registered tabs only; it needs the record's shell
  pid), `notify list`, `notify close`, and a background run at launch. A tab whose marker never shows keeps its old files.
- A record whose shell is dead was not unregistered, so its tab was closed under the agent: closing a tab never runs the launcher's `finally`
  (verified on PowerShell 5.1 and 7). `Get-AgentSessions` moves such a record to `.sessions/closed/` (last 30) and deletes the tab's side
  files. `notify reopen` opens those in the current window (`wt -w 0 new-tab`) through the same `__resume` path, token `reopen`.
  `notify close` unregisters directly, so tabs it closes never land on the closed list.
- `popup.ps1` closes itself when the shell of its registered tab is gone.
- `Get-AgentResumeArguments` strips each CLI's session flags case-sensitively (Codex `-c` is config, `-C` is the directory; pi `-c` is continue).
- `AGENTIC_NOTIFY_DIR` overrides the state directory. Tests rely on it; nothing else should set it.

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
