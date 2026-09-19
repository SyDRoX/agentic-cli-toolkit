// agentic-cli-notify bridge for pi.
//
// pi has no external hook config like Claude Code or Codex, so the same
// notifications are driven from an extension:
//
//   before_agent_start -> resume    (user just submitted a prompt)
//   agent_settled      -> attention (pi will not continue on its own)
//   ui_prompt_start    -> attention (pi is blocked on a confirm/select dialog)
//
// The notifier is spawned detached and its output discarded, so a broken or
// missing install can never stall or crash the session.

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
      { detached: true, stdio: "ignore", windowsHide: true },
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
    notify("resume");
  });

  pi.on("before_agent_start", async () => {
    notify("resume");
  });

  pi.on("agent_settled", async () => {
    notify("attention");
  });

  pi.on("ui_prompt_start", async () => {
    notify("attention");
  });
}
