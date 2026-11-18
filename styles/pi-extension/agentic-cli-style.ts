// Response styles for pi.
//
// launch-pi.ps1 loads this file with --extension and passes the tab's style in
// AGENTIC_STYLE and the styles directory in AGENTIC_STYLES_DIR. The rules go into
// the system prompt as their own section, so pi patches only that section when the
// style changes and the cached prompt prefix survives.
//
//   /style            -> next style in the catalog, then off
//   /style <name>     -> that style (catalog key or label)
//   /style off        -> no style
//
// A switch lasts until pi exits: the layout preset is the source of truth, and the
// launcher passes it again on the next launch.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const SECTION = "response_style";
const STATUS_KEY = "style";
const OFF_WORDS = ["off", "none", "default"];

interface Style {
  key: string;
  label: string;
  text: string;
}

function loadCatalog(): Style[] {
  const dir = process.env.AGENTIC_STYLES_DIR;
  if (!dir) return [];
  try {
    const catalogPath = join(dir, "styles.json");
    if (!existsSync(catalogPath)) return [];
    // PowerShell 5.1 tools may leave a BOM, which JSON.parse rejects.
    const raw = readFileSync(catalogPath, "utf8").replace(/^﻿/, "");
    const entries = JSON.parse(raw) as Record<string, { label?: string; file?: string }>;
    const styles: Style[] = [];
    for (const [key, entry] of Object.entries(entries)) {
      const rulesPath = join(dir, String(entry.file ?? ""));
      if (!entry.file || !existsSync(rulesPath)) continue;
      styles.push({
        key: key.toLowerCase(),
        label: String(entry.label ?? key),
        text: readFileSync(rulesPath, "utf8").replace(/^﻿/, "").trim(),
      });
    }
    return styles;
  } catch {
    return [];
  }
}

function findStyle(styles: Style[], name: string): Style | undefined {
  const wanted = name.trim().toLowerCase();
  if (!wanted) return undefined;
  return styles.find((s) => s.key === wanted || s.label.toLowerCase() === wanted);
}

export default function (pi: any) {
  const styles = loadCatalog();
  let active: Style | undefined = findStyle(styles, process.env.AGENTIC_STYLE ?? "");

  const showStatus = (ctx: any) => {
    try {
      ctx.ui.setStatus(STATUS_KEY, active ? `[${active.label}]` : undefined);
    } catch {
      // Print and JSON modes have no footer.
    }
  };

  pi.on("session_start", async (_event: any, ctx: any) => {
    showStatus(ctx);
  });

  pi.on("before_agent_start", async (event: any) => {
    const sections = event.systemPromptOptions?.sections;
    if (!sections) return;
    if (active) sections[SECTION] = active.text;
    else delete sections[SECTION];
  });

  pi.registerCommand("style", {
    description: "Switch the response style: /style [" + styles.map((s) => s.key).join("|") + "|off]",
    getArgumentCompletions: (prefix: string) => {
      const wanted = prefix.trim().toLowerCase();
      const names = [...styles.map((s) => s.key), "off"].filter((n) => n.startsWith(wanted));
      return names.length ? names.map((n) => ({ value: n, label: n })) : null;
    },
    handler: async (args: string, ctx: any) => {
      const wanted = (args ?? "").trim().toLowerCase();

      if (styles.length === 0) {
        ctx.ui.notify("No response styles found. AGENTIC_STYLES_DIR is not set or is empty.", "warning");
        return;
      }

      if (!wanted) {
        const index = active ? styles.findIndex((s) => s.key === active!.key) : -1;
        active = index + 1 < styles.length ? styles[index + 1] : undefined;
      } else if (OFF_WORDS.includes(wanted)) {
        active = undefined;
      } else {
        const found = findStyle(styles, wanted);
        if (!found) {
          ctx.ui.notify(`Unknown style '${wanted}'. Use: ${styles.map((s) => s.key).join(", ")}, off`, "warning");
          return;
        }
        active = found;
      }

      showStatus(ctx);
      ctx.ui.notify(`Response style: ${active ? active.label : "off"} (from the next prompt)`, "info");
    },
  });
}
