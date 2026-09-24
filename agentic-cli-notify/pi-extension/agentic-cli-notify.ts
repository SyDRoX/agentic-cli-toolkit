// agentic-cli-notify bridge for pi.
//
// pi has no external hook config like Claude Code or Codex, so the same
// notifications are driven from an extension:
//
//   session_start      -> resume    (tab is up, capture its window handle)
//   before_agent_start -> resume    (user just submitted a prompt)
//   agent_settled      -> attention (pi will not continue on its own)
//   ui_prompt_start    -> attention (pi is blocked on a confirm/select dialog)
//   ui_prompt_end      -> resume    (the dialog is answered)
//
// Attention is only raised while a turn the user started is in flight, and
// never for a turn the user aborted, because in both of those cases the user
// is already looking at the tab and the popup is pure noise.
//
// The notifier's output is discarded, so a broken or missing install can never
// stall or crash the session.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const NOTIFY_SCRIPT = join(
  homedir(),
  ".claude",
  "hooks",
  "agentic-cli-notify",
  "notify.ps1",
);

// True from the moment the user submits a prompt until pi settles. Startup
// dialogs (project trust, model pickers) and any other UI that pi raises while
// no turn is running are the user's own doing, so they must not notify.
let turnInFlight = false;
// Set when the assistant message ends in an abort: the user pressed escape, so
// the settle that follows is not news to them.
let turnAborted = false;

// Outside Windows Terminal there is no per-tab session to notify about, and
// every tab would otherwise share the "default" state files.
function sessionIsUsable(): boolean {
  const session = process.env.WT_SESSION;
  return typeof session === "string" && /^[a-zA-Z0-9-]+$/.test(session);
}

function notify(action: "attention" | "resume"): void {
  try {
    if (process.platform !== "win32") return;
    if (!sessionIsUsable()) return;
    if (!existsSync(NOTIFY_SCRIPT)) return;
    const child = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        NOTIFY_SCRIPT,
        "-Action",
        action,
        "-Agent",
        "Pi",
      ],
      // No `detached`. DETACHED_PROCESS leaves powershell.exe without a
      // console and it exits immediately with code 0 without running the
      // script, so every notification was silently dropped. `windowsHide`
      // gives the child its own hidden console (CREATE_NO_WINDOW) instead,
      // which also keeps powershell.exe from renaming the Windows Terminal
      // tab to "Windows PowerShell".
      { stdio: "ignore", windowsHide: true },
    );
    child.on("error", () => {});
    child.unref();
  } catch {
    // Notification failures must not interfere with the conversation.
  }
}

export default function (pi: any) {
  // Capture the current Windows Terminal tab as soon as pi starts. Without
  // this, the first notification can be dropped because no per-session HWND
  // file exists until the first prompt is submitted.
  pi.on("session_start", async () => {
    turnInFlight = false;
    turnAborted = false;
    notify("resume");
  });

  pi.on("before_agent_start", async () => {
    turnInFlight = true;
    turnAborted = false;
    notify("resume");
  });

  // message_end is notification-only, so reading the stop reason here costs
  // nothing. agent_settled itself carries no outcome.
  pi.on("message_end", async (event: any) => {
    if (event?.message?.role !== "assistant") return;
    if (event?.message?.stopReason === "aborted") turnAborted = true;
  });

  pi.on("agent_settled", async () => {
    const aborted = turnAborted;
    const started = turnInFlight;
    turnInFlight = false;
    turnAborted = false;
    if (!started) return;
    // An abort can leave a popup from an earlier dialog on screen; clear it
    // instead of raising a new one.
    notify(aborted ? "resume" : "attention");
  });

  pi.on("ui_prompt_start", async () => {
    if (!turnInFlight) return;
    notify("attention");
  });

  pi.on("ui_prompt_end", async () => {
    if (!turnInFlight) return;
    notify("resume");
  });
}
