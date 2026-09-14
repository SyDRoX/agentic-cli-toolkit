#!/usr/bin/env python3
"""Basic UI to compose multi-window, mixed-agent Windows Terminal layouts.

Builds JSON presets consumed by Invoke-CustomLayout.ps1 (Claude / Codex / Pi /
Cursor Agent tabs in any combination).
"""

from __future__ import annotations

import json
import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import customtkinter as ctk

from ui_theme import (
    FONT_BODY,
    FONT_LABEL,
    apply_appearance_mode,
    apply_titlebar_color,
    detect_os_mode,
    listbox_kwargs,
    resolve_color,
    style_treeview,
)


def _root_dir() -> Path:
    """Repo root: the folder holding the exe when frozen, else this file's folder.

    A onefile build unpacks to a temp dir, so __file__ would point away from the
    custom-layouts/, repos.json and ps1-scripts/ that must stay beside the exe.
    """
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


ROOT = _root_dir()
PRESETS_DIR = ROOT / "custom-layouts"
REPOS_FILE = ROOT / "repos.json"
INVOKE_PS1 = ROOT / "ps1-scripts" / "Invoke-CustomLayout.ps1"
SLOT_START = 100

DEFAULT_REPOS = [
    ("PS-1", r"C:\Repos\PotatoSandwich"),
    ("PS-2", r"C:\repos2\PotatoSandwich2"),
    ("PS-3", r"C:\repos3\PotatoSandwich3"),
    ("ORMI-1", r"C:\Repos\ormi-unity"),
    ("ORMI-2", r"C:\repos2\ormi-unity2"),
    ("ORMI-3", r"C:\repos3\ormi-unity3"),
]

# Display label -> JSON agent key (matches Invoke-CustomLayout.ps1)
AGENTS = [
    ("Claude", "claude"),
    ("Codex", "codex"),
    ("Pi (hy4)", "pi"),
    ("Cursor", "cursor"),
]
AGENT_BY_KEY = {key: label for label, key in AGENTS}
AGENT_BY_LABEL = {label: key for label, key in AGENTS}

# Model choices per agent (editable combos - typing a value not listed is fine).
# Claude: --model accepts these aliases or a full model id (see `claude --help`).
CLAUDE_MODELS = [
    "", "opus", "sonnet", "fable",
    "claude-opus-5", "claude-sonnet-5", "claude-fable-5-1",
    "claude-opus-4-8", "claude-opus-4-6", "claude-haiku-4-5-20251001",
]
# Codex: real slugs from ~/.codex/models_cache.json (-m / -c model=).
CODEX_MODELS = [
    "", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
]
MODELS_BY_AGENT = {"claude": CLAUDE_MODELS, "codex": CODEX_MODELS}
# Preselect a real model rather than the blank "use CLI default" entry.
DEFAULT_MODEL_BY_AGENT = {"claude": "sonnet", "codex": "gpt-5.6-sol"}

# --effort (claude) / model_reasoning_effort (codex) - same value set, both real.
EFFORT_LEVELS = ["", "low", "medium", "high", "xhigh", "max"]
DEFAULT_EFFORT = "medium"

# Claude only: 0.25m/0.5m -> --autocompact tokens; MAX -> [1m] model suffix + --autocompact 1M.
# Codex has no equivalent CLI flag, so this is ignored for codex/pi/cursor tabs.
CONTEXT_WINDOWS = ["default", "0.25m", "0.5m", "MAX"]


def load_repos() -> list[dict[str, str]]:
    """Load the editable repo catalog, falling back to the original defaults."""
    if not REPOS_FILE.exists():
        return [{"label": label, "path": path} for label, path in DEFAULT_REPOS]
    try:
        data = json.loads(REPOS_FILE.read_text(encoding="utf-8"))
        repos = data.get("repos", []) if isinstance(data, dict) else data if isinstance(data, list) else []
        result = [
            {"label": str(repo["label"]).strip(), "path": str(repo["path"]).strip()}
            for repo in repos
            if isinstance(repo, dict) and repo.get("label") and repo.get("path")
        ]
        return result or [{"label": label, "path": path} for label, path in DEFAULT_REPOS]
    except (OSError, json.JSONDecodeError, KeyError, TypeError):
        return [{"label": label, "path": path} for label, path in DEFAULT_REPOS]


def next_window_num(used: set[int]) -> int:
    n = SLOT_START
    while n in used:
        n += 1
    return n


def collect_used_window_nums(exclude: Path | None = None) -> set[int]:
    used: set[int] = set()
    if not PRESETS_DIR.exists():
        return used
    for path in PRESETS_DIR.glob("*.json"):
        if exclude and path.resolve() == exclude.resolve():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for win in data.get("windows", []):
            num = win.get("windowNum")
            if isinstance(num, int):
                used.add(num)
    return used


class Spinbox(ctk.CTkFrame):
    """customtkinter has no spinbox, so pair a themed entry with clamped -/+ buttons."""

    def __init__(
        self,
        master: any,
        *,
        variable: tk.IntVar,
        from_: int,
        to: int,
        mode: str,
        width: int = 54,
    ) -> None:
        super().__init__(master, fg_color="transparent")
        self._var = variable
        self._from = from_
        self._to = to
        ctk.CTkButton(
            self,
            text="-",
            width=26,
            font=FONT_BODY,
            command=lambda: self._step(-1),
            fg_color=resolve_color("button", mode),
            hover_color=resolve_color("button_hover", mode),
            text_color=resolve_color("text", mode),
        ).pack(side=tk.LEFT)
        ctk.CTkEntry(
            self,
            textvariable=variable,
            width=width,
            justify="center",
            font=FONT_BODY,
            fg_color=resolve_color("surface", mode),
            border_color=resolve_color("line", mode),
            text_color=resolve_color("text", mode),
        ).pack(side=tk.LEFT, padx=2)
        ctk.CTkButton(
            self,
            text="+",
            width=26,
            font=FONT_BODY,
            command=lambda: self._step(1),
            fg_color=resolve_color("button", mode),
            hover_color=resolve_color("button_hover", mode),
            text_color=resolve_color("text", mode),
        ).pack(side=tk.LEFT)

    def _step(self, delta: int) -> None:
        try:
            current = int(self._var.get())
        except (tk.TclError, ValueError):
            current = self._from
        self._var.set(max(self._from, min(self._to, current + delta)))


class LayoutUI(ctk.CTk):
    def __init__(self) -> None:
        super().__init__()
        self.mode = detect_os_mode()
        apply_appearance_mode(self.mode)
        style_treeview(self.mode)

        self.title("Dev Layout Composer")
        self.geometry("1120x760")
        self.minsize(980, 600)
        self.configure(fg_color=resolve_color("frame", self.mode))

        PRESETS_DIR.mkdir(parents=True, exist_ok=True)

        self.preset_var = tk.StringVar()
        self.window_name_var = tk.StringVar(value="Terminal 1")
        self.monitor_var = tk.IntVar(value=0)
        self.window_num_var = tk.IntVar(value=SLOT_START)
        self.repos = load_repos()
        self.repo_var = tk.StringVar(value=self.repos[0]["label"] if self.repos else "")
        self.tab_title_var = tk.StringVar(value="")
        self.agent_var = tk.StringVar(value=AGENTS[0][0])
        self.model_var = tk.StringVar(value=DEFAULT_MODEL_BY_AGENT.get(AGENT_BY_LABEL[AGENTS[0][0]], ""))
        self.effort_var = tk.StringVar(value=DEFAULT_EFFORT)
        self.context_var = tk.StringVar(value=CONTEXT_WINDOWS[0])

        # windows: list[{name, windowNum, targetMonitor, tabs:[{title,workingDir,agent}]}]
        self.windows: list[dict] = []
        self.current_window_index: int | None = None
        self._preset_path: Path | None = None

        self._build()
        self._refresh_model_choices()
        self._new_preset(initial=True)
        self._refresh_preset_list()

    # --- themed widget factories ----------------------------------------

    def _label(self, master: any, text: str, *, width: int = 0, muted: bool = False) -> ctk.CTkLabel:
        return ctk.CTkLabel(
            master,
            text=text,
            width=width,
            anchor="w",
            font=FONT_BODY,
            text_color=resolve_color("muted" if muted else "text", self.mode),
        )

    def _button(
        self, master: any, text: str, command: any, *, width: int = 80, accent: bool = False
    ) -> ctk.CTkButton:
        return ctk.CTkButton(
            master,
            text=text,
            command=command,
            width=width,
            font=FONT_BODY,
            corner_radius=6,
            fg_color=resolve_color("accent" if accent else "button", self.mode),
            hover_color=resolve_color("accent_hover" if accent else "button_hover", self.mode),
            text_color=resolve_color("accent_text" if accent else "text", self.mode),
        )

    def _entry(self, master: any, variable: tk.Variable, *, width: int = 140) -> ctk.CTkEntry:
        return ctk.CTkEntry(
            master,
            textvariable=variable,
            width=width,
            font=FONT_BODY,
            fg_color=resolve_color("surface", self.mode),
            border_color=resolve_color("line", self.mode),
            text_color=resolve_color("text", self.mode),
        )

    def _option(
        self, master: any, variable: tk.Variable, values: list[str], *, width: int = 120, command: any = None
    ) -> ctk.CTkOptionMenu:
        return ctk.CTkOptionMenu(
            master,
            variable=variable,
            values=values,
            width=width,
            font=FONT_BODY,
            command=command,
            fg_color=resolve_color("button", self.mode),
            button_color=resolve_color("accent", self.mode),
            button_hover_color=resolve_color("accent_hover", self.mode),
            text_color=resolve_color("text", self.mode),
            dropdown_fg_color=resolve_color("panel", self.mode),
            dropdown_hover_color=resolve_color("button_hover", self.mode),
            dropdown_text_color=resolve_color("text", self.mode),
        )

    def _combo(
        self, master: any, variable: tk.Variable, values: list[str], *, width: int = 150, command: any = None
    ) -> ctk.CTkComboBox:
        return ctk.CTkComboBox(
            master,
            variable=variable,
            values=values,
            width=width,
            font=FONT_BODY,
            command=command,
            fg_color=resolve_color("surface", self.mode),
            border_color=resolve_color("line", self.mode),
            button_color=resolve_color("accent", self.mode),
            button_hover_color=resolve_color("accent_hover", self.mode),
            text_color=resolve_color("text", self.mode),
            dropdown_fg_color=resolve_color("panel", self.mode),
            dropdown_hover_color=resolve_color("button_hover", self.mode),
            dropdown_text_color=resolve_color("text", self.mode),
        )

    def _section(self, parent: any, title: str) -> tuple[ctk.CTkFrame, ctk.CTkFrame]:
        """Stand-in for ttk.LabelFrame: an eyebrow caption over a bordered panel."""
        outer = ctk.CTkFrame(parent, fg_color="transparent")
        ctk.CTkLabel(
            outer,
            text=title.upper(),
            font=FONT_LABEL,
            anchor="w",
            text_color=resolve_color("muted", self.mode),
        ).pack(fill=tk.X, padx=4, pady=(0, 3))
        inner = ctk.CTkFrame(
            outer,
            fg_color=resolve_color("panel", self.mode),
            border_color=resolve_color("line", self.mode),
            border_width=1,
            corner_radius=6,
        )
        inner.pack(fill=tk.BOTH, expand=True)
        return outer, inner

    # --- layout ----------------------------------------------------------

    def _build(self) -> None:
        top = ctk.CTkFrame(self, fg_color="transparent")
        top.pack(fill=tk.X, padx=8, pady=8)

        self._label(top, "Preset").pack(side=tk.LEFT)
        self.preset_combo = self._combo(
            top, self.preset_var, [], width=220, command=lambda _v: self._load_selected_preset()
        )
        self.preset_combo.pack(side=tk.LEFT, padx=(6, 4))

        self._button(top, "New", self._new_preset).pack(side=tk.LEFT, padx=2)
        self._button(top, "Load", self._browse_load_preset).pack(side=tk.LEFT, padx=2)
        self._button(top, "Save", self._save_preset).pack(side=tk.LEFT, padx=2)
        self._button(top, "Delete", self._delete_preset).pack(side=tk.LEFT, padx=2)
        self._button(top, "Repos...", self._manage_repos).pack(side=tk.LEFT, padx=(12, 2))
        self._button(top, "Launch", self._launch, accent=True).pack(side=tk.RIGHT, padx=2)
        self._button(top, "Dry run", lambda: self._launch(dry_run=True)).pack(side=tk.RIGHT, padx=2)

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.pack(fill=tk.BOTH, expand=True, padx=8)

        windows_outer, windows_frame = self._section(body, "Terminal windows")
        windows_outer.pack(fill=tk.X, pady=(0, 8))

        self.window_list = tk.Listbox(
            windows_frame, exportselection=False, height=6, **listbox_kwargs(self.mode)
        )
        self.window_list.pack(fill=tk.X, expand=True, padx=8, pady=(8, 4))
        self.window_list.bind("<<ListboxSelect>>", lambda _e: self._on_select_window())
        self.window_list.bind("<Delete>", lambda _e: self._remove_window())

        win_btns = ctk.CTkFrame(windows_frame, fg_color="transparent")
        win_btns.pack(fill=tk.X, padx=8, pady=(0, 8))
        self._button(win_btns, "Add window", self._add_window, width=100).pack(side=tk.LEFT, padx=2)
        self._button(win_btns, "Remove", self._remove_window).pack(side=tk.LEFT, padx=2)

        right = ctk.CTkFrame(body, fg_color="transparent")
        right.pack(fill=tk.BOTH, expand=True)

        form_outer, form = self._section(right, "Selected window")
        form_outer.pack(fill=tk.X)

        row = ctk.CTkFrame(form, fg_color="transparent")
        row.pack(fill=tk.X, padx=8, pady=(8, 2))
        self._label(row, "Name", width=92).pack(side=tk.LEFT)
        self._entry(row, self.window_name_var).pack(side=tk.LEFT, fill=tk.X, expand=True)

        row = ctk.CTkFrame(form, fg_color="transparent")
        row.pack(fill=tk.X, padx=8, pady=2)
        self._label(row, "Monitor", width=92).pack(side=tk.LEFT)
        Spinbox(row, variable=self.monitor_var, from_=0, to=3, mode=self.mode).pack(side=tk.LEFT)
        self._label(row, "(0 = leftmost)", muted=True).pack(side=tk.LEFT, padx=8)

        row = ctk.CTkFrame(form, fg_color="transparent")
        row.pack(fill=tk.X, padx=8, pady=2)
        self._label(row, "Window slot", width=92).pack(side=tk.LEFT)
        Spinbox(row, variable=self.window_num_var, from_=SLOT_START, to=999, mode=self.mode).pack(
            side=tk.LEFT
        )
        self._label(row, "keep stable for session resume", muted=True).pack(side=tk.LEFT, padx=8)

        self._button(form, "Apply window settings", self._apply_window_settings, width=150).pack(
            anchor=tk.E, padx=8, pady=(6, 8)
        )

        tabs_outer, tabs_frame = self._section(right, "Tabs (repo + agent)")
        tabs_outer.pack(fill=tk.BOTH, expand=True, pady=(8, 0))

        cols = ("title", "agent", "model", "effort", "context", "path")
        self.tabs_tree = ttk.Treeview(tabs_frame, columns=cols, show="headings", height=10)
        self.tabs_tree.heading("title", text="Title")
        self.tabs_tree.heading("agent", text="Agent")
        self.tabs_tree.heading("model", text="Model")
        self.tabs_tree.heading("effort", text="Effort")
        self.tabs_tree.heading("context", text="Context window")
        self.tabs_tree.heading("path", text="Working dir")
        self.tabs_tree.column("title", width=90, stretch=False)
        self.tabs_tree.column("agent", width=90, stretch=False)
        self.tabs_tree.column("model", width=110, stretch=False)
        self.tabs_tree.column("effort", width=70, stretch=False)
        self.tabs_tree.column("context", width=130, stretch=False)
        self.tabs_tree.column("path", width=280)
        self.tabs_tree.pack(fill=tk.BOTH, expand=True, padx=8, pady=(8, 0))
        self.tabs_tree.bind("<Double-1>", lambda _e: self._edit_tab())
        self.tabs_tree.bind("<Delete>", lambda _e: self._remove_tab())

        fields_row = ctk.CTkFrame(tabs_frame, fg_color="transparent")
        fields_row.pack(fill=tk.X, padx=8, pady=(8, 0))

        self._label(fields_row, "Repo").pack(side=tk.LEFT)
        self.repo_combo = self._option(
            fields_row, self.repo_var, [r["label"] for r in self.repos] or [""], width=110
        )
        self.repo_combo.pack(side=tk.LEFT, padx=4)

        self._label(fields_row, "Title").pack(side=tk.LEFT, padx=(8, 0))
        self._entry(fields_row, self.tab_title_var, width=110).pack(side=tk.LEFT, padx=4)

        self._label(fields_row, "Agent").pack(side=tk.LEFT, padx=(8, 0))
        self.agent_combo = self._option(
            fields_row,
            self.agent_var,
            [a[0] for a in AGENTS],
            width=110,
            command=lambda _v: self._refresh_model_choices(),
        )
        self.agent_combo.pack(side=tk.LEFT, padx=4)

        self._label(fields_row, "Model").pack(side=tk.LEFT, padx=(8, 0))
        self.model_combo = self._combo(fields_row, self.model_var, CLAUDE_MODELS, width=150)
        self.model_combo.pack(side=tk.LEFT, padx=4)

        self._label(fields_row, "Effort").pack(side=tk.LEFT, padx=(8, 0))
        self._option(fields_row, self.effort_var, EFFORT_LEVELS, width=90).pack(side=tk.LEFT, padx=4)

        self._label(fields_row, "Context window").pack(side=tk.LEFT, padx=(8, 0))
        self._option(fields_row, self.context_var, CONTEXT_WINDOWS, width=90).pack(side=tk.LEFT, padx=4)

        add_row = ctk.CTkFrame(tabs_frame, fg_color="transparent")
        add_row.pack(fill=tk.X, padx=8, pady=(4, 8))

        self._button(add_row, "Add tab", self._add_tab).pack(side=tk.LEFT, padx=4)
        self._button(add_row, "Edit tab", self._edit_tab).pack(side=tk.LEFT, padx=2)
        self._button(add_row, "Remove tab", self._remove_tab, width=90).pack(side=tk.LEFT)
        self._button(add_row, "Move up", lambda: self._move_tab(-1)).pack(side=tk.LEFT, padx=4)
        self._button(add_row, "Move down", lambda: self._move_tab(1)).pack(side=tk.LEFT)

        hint = ctk.CTkLabel(
            self,
            text="Example: Window1 [PS-1 Pi] [PS-2 Codex] [ORMI-1 Cursor]  ·  "
            "Window2 [ORMI-1 Claude] [ORMI-2 Codex] [ORMI-3 Cursor]",
            anchor="w",
            font=FONT_BODY,
            text_color=resolve_color("dim", self.mode),
        )
        hint.pack(fill=tk.X, padx=8, pady=8)

    # --- modal helpers ---------------------------------------------------

    def _toplevel(self, parent: any, title: str) -> ctk.CTkToplevel:
        dialog = ctk.CTkToplevel(parent)
        dialog.title(title)
        dialog.transient(parent)
        dialog.configure(fg_color=resolve_color("frame", self.mode))

        def on_mapped() -> None:
            if not dialog.winfo_exists():
                return
            # grab_set() on an unmapped window raises "window not viewable", and
            # customtkinter's own titlebar tint missed this window for the same reason.
            dialog.grab_set()
            apply_titlebar_color(dialog, self.mode)

        dialog.after(200, on_mapped)
        return dialog

    # --- preset CRUD -----------------------------------------------------

    def _refresh_preset_list(self) -> None:
        names = sorted(p.stem for p in PRESETS_DIR.glob("*.json"))
        current = self.preset_var.get()
        self.preset_combo.configure(values=names or [""])
        self.preset_var.set(current)

    def _new_preset(self, initial: bool = False) -> None:
        used = collect_used_window_nums()
        slot = next_window_num(used)
        self._preset_path = None
        self.preset_var.set("Untitled")
        self.windows = [
            {
                "name": "Terminal 1",
                "windowNum": slot,
                "targetMonitor": 0,
                "tabs": [],
            }
        ]
        self.current_window_index = 0
        self._refresh_window_list()
        self._load_window_into_form(0)
        if not initial:
            self.preset_combo.set("Untitled")

    def _browse_load_preset(self) -> None:
        path = filedialog.askopenfilename(
            title="Load preset",
            initialdir=str(PRESETS_DIR),
            filetypes=(("Preset JSON", "*.json"), ("All files", "*.*")),
        )
        if path:
            self._load_preset_path(Path(path))

    def _load_selected_preset(self) -> None:
        """Load the preset selected in the dropdown."""
        name = self.preset_var.get().strip()
        if name:
            self._load_preset_path(PRESETS_DIR / f"{name}.json")

    def _load_preset_path(self, path: Path) -> None:
        if not path.exists():
            messagebox.showerror("Missing preset", f"No file: {path}")
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            messagebox.showerror("Bad preset", str(exc))
            return
        self._preset_path = path
        self.preset_var.set(path.stem)
        self.windows = data.get("windows") or []
        if not self.windows:
            self.windows = [
                {
                    "name": "Terminal 1",
                    "windowNum": next_window_num(collect_used_window_nums(path)),
                    "targetMonitor": 0,
                    "tabs": [],
                }
            ]
        self.current_window_index = 0
        self._refresh_window_list()
        self._load_window_into_form(0)

    def _save_preset(self) -> None:
        self._apply_window_settings(silent=True)
        name = self.preset_var.get().strip()
        if not name or name.lower() == "untitled":
            messagebox.showerror("Name required", "Set a preset name before saving.")
            return
        if any(not w.get("tabs") for w in self.windows):
            if not messagebox.askyesno(
                "Empty window",
                "At least one window has no tabs. Save anyway?",
            ):
                return

        nums = [w["windowNum"] for w in self.windows]
        if len(nums) != len(set(nums)):
            messagebox.showerror(
                "Duplicate slots",
                "Each terminal window needs a unique window slot number.",
            )
            return

        path = (
            self._preset_path
            if self._preset_path and self._preset_path.stem == name
            else PRESETS_DIR / f"{name}.json"
        )
        payload = {"name": name, "windows": self.windows}
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        self._preset_path = path
        self._refresh_preset_list()
        self.preset_var.set(name)
        messagebox.showinfo("Saved", f"Wrote {path}")

    def _delete_preset(self) -> None:
        name = self.preset_var.get().strip()
        path = PRESETS_DIR / f"{name}.json"
        if not path.exists():
            messagebox.showerror("Missing", f"No preset file for '{name}'.")
            return
        if not messagebox.askyesno("Delete", f"Delete preset '{name}'?"):
            return
        path.unlink(missing_ok=True)
        self._refresh_preset_list()
        self._new_preset()

    # --- repo catalog ----------------------------------------------------

    def _save_repos(self) -> None:
        try:
            REPOS_FILE.write_text(
                json.dumps({"repos": self.repos}, indent=2) + "\n", encoding="utf-8"
            )
        except OSError as exc:
            messagebox.showerror("Repo catalog", f"Could not save {REPOS_FILE}: {exc}")

    def _refresh_repo_combo(self) -> None:
        labels = [repo["label"] for repo in self.repos]
        self.repo_combo.configure(values=labels or [""])
        if labels and self.repo_var.get() not in labels:
            self.repo_var.set(labels[0])
        elif not labels:
            self.repo_var.set("")

    def _manage_repos(self) -> None:
        dialog = self._toplevel(self, "Repository catalog")
        dialog.geometry("620x360")

        tree = ttk.Treeview(dialog, columns=("label", "path"), show="headings", selectmode="browse")
        tree.heading("label", text="Name")
        tree.heading("path", text="Working directory")
        tree.column("label", width=150, stretch=False)
        tree.column("path", width=420)
        tree.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        def refresh() -> None:
            tree.delete(*tree.get_children())
            for repo in self.repos:
                tree.insert("", tk.END, values=(repo["label"], repo["path"]))

        def selected() -> int | None:
            selection = tree.selection()
            return tree.index(selection[0]) if selection else None

        buttons = ctk.CTkFrame(dialog, fg_color="transparent")
        buttons.pack(fill=tk.X, padx=8, pady=(0, 8))

        def add() -> None:
            editor = self._edit_repo_dialog(dialog)
            dialog.wait_window(editor)
            refresh()

        self._button(buttons, "Add", add).pack(side=tk.LEFT, padx=2)

        def edit() -> None:
            index = selected()
            if index is not None:
                editor = self._edit_repo_dialog(dialog, index)
                dialog.wait_window(editor)
                refresh()

        def remove() -> None:
            index = selected()
            if index is None:
                return
            repo = self.repos[index]
            if not messagebox.askyesno("Remove repo", f"Remove '{repo['label']}' from the catalog?", parent=dialog):
                return
            del self.repos[index]
            self._save_repos()
            self._refresh_repo_combo()
            refresh()

        self._button(buttons, "Edit", edit).pack(side=tk.LEFT, padx=2)
        self._button(buttons, "Remove", remove).pack(side=tk.LEFT, padx=2)
        self._button(buttons, "Close", dialog.destroy).pack(side=tk.RIGHT, padx=2)
        tree.bind("<Double-1>", lambda _event: edit())
        refresh()

    def _edit_repo_dialog(self, parent: any, index: int | None = None) -> ctk.CTkToplevel:
        repo = self.repos[index] if index is not None else {"label": "", "path": ""}
        dialog = self._toplevel(parent, "Edit repository" if index is not None else "Add repository")

        label_var = tk.StringVar(value=repo["label"])
        path_var = tk.StringVar(value=repo["path"])
        form = ctk.CTkFrame(dialog, fg_color="transparent")
        form.pack(fill=tk.BOTH, expand=True, padx=12, pady=12)
        self._label(form, "Name", width=110).grid(row=0, column=0, sticky="w", pady=4)
        self._entry(form, label_var, width=300).grid(row=0, column=1, columnspan=2, sticky="ew", pady=4)
        self._label(form, "Working directory", width=110).grid(row=1, column=0, sticky="w", pady=4)
        self._entry(form, path_var, width=300).grid(row=1, column=1, sticky="ew", pady=4)

        def browse() -> None:
            chosen = filedialog.askdirectory(parent=dialog, initialdir=path_var.get() or str(ROOT))
            if chosen:
                path_var.set(chosen)

        self._button(form, "Browse...", browse).grid(row=1, column=2, padx=(6, 0))
        form.columnconfigure(1, weight=1)

        def save() -> None:
            label, path = label_var.get().strip(), path_var.get().strip()
            if not label or not path:
                messagebox.showerror("Repo", "Both name and working directory are required.", parent=dialog)
                return
            for i, existing in enumerate(self.repos):
                if i != index and existing["label"].casefold() == label.casefold():
                    messagebox.showerror("Repo", "Repository names must be unique.", parent=dialog)
                    return
            item = {"label": label, "path": path}
            if index is None:
                self.repos.append(item)
            else:
                old_repo = self.repos[index]
                self.repos[index] = item
                for window in self.windows:
                    for tab in window.get("tabs", []):
                        if tab.get("title") == old_repo["label"] and tab.get("workingDir") == old_repo["path"]:
                            tab.update(title=label, workingDir=path)
                self._refresh_tabs_tree()
            self._save_repos()
            self._refresh_repo_combo()
            self.repo_var.set(label)
            dialog.destroy()

        actions = ctk.CTkFrame(form, fg_color="transparent")
        actions.grid(row=2, column=0, columnspan=3, sticky="e", pady=(12, 0))
        self._button(actions, "Save", save).pack(side=tk.LEFT, padx=2)
        self._button(actions, "Cancel", dialog.destroy).pack(side=tk.LEFT, padx=2)
        dialog.focus_set()
        return dialog

    # --- windows ---------------------------------------------------------

    def _refresh_window_list(self) -> None:
        self.window_list.delete(0, tk.END)
        for i, win in enumerate(self.windows):
            tabs = win.get("tabs") or []
            summary = ", ".join(
                f"{t['title']}-{AGENT_BY_KEY.get(t['agent'], t['agent'])}" for t in tabs
            ) or "(empty)"
            self.window_list.insert(
                tk.END,
                f"{i + 1}. {win.get('name', 'Window')}  [{summary}]",
            )
        if self.current_window_index is not None and self.windows:
            self.window_list.selection_clear(0, tk.END)
            self.window_list.selection_set(self.current_window_index)
            self.window_list.activate(self.current_window_index)

    def _on_select_window(self) -> None:
        sel = self.window_list.curselection()
        if not sel:
            return
        self._apply_window_settings(silent=True)
        self._load_window_into_form(sel[0])

    def _load_window_into_form(self, index: int) -> None:
        self.current_window_index = index
        win = self.windows[index]
        self.window_name_var.set(win.get("name", f"Terminal {index + 1}"))
        self.monitor_var.set(int(win.get("targetMonitor", 0)))
        self.window_num_var.set(int(win.get("windowNum", SLOT_START)))
        self._refresh_tabs_tree()

    def _apply_window_settings(self, silent: bool = False) -> None:
        if self.current_window_index is None or not self.windows:
            return
        win = self.windows[self.current_window_index]
        try:
            monitor = int(self.monitor_var.get())
            slot = int(self.window_num_var.get())
        except (tk.TclError, ValueError):
            messagebox.showerror("Numbers", "Monitor and window slot must be whole numbers.")
            return
        win["name"] = self.window_name_var.get().strip() or win.get("name", "Terminal")
        win["targetMonitor"] = monitor
        win["windowNum"] = slot
        self._refresh_window_list()
        if not silent:
            messagebox.showinfo("Updated", "Window settings applied.")

    def _add_window(self) -> None:
        self._apply_window_settings(silent=True)
        used = {w["windowNum"] for w in self.windows} | collect_used_window_nums(
            self._preset_path
        )
        slot = next_window_num(used)
        self.windows.append(
            {
                "name": f"Terminal {len(self.windows) + 1}",
                "windowNum": slot,
                "targetMonitor": 0,
                "tabs": [],
            }
        )
        self.current_window_index = len(self.windows) - 1
        self._refresh_window_list()
        self._load_window_into_form(self.current_window_index)

    def _remove_window(self) -> None:
        if len(self.windows) <= 1:
            messagebox.showinfo("Keep one", "At least one terminal window is required.")
            return
        if self.current_window_index is None:
            return
        del self.windows[self.current_window_index]
        self.current_window_index = min(self.current_window_index, len(self.windows) - 1)
        self._refresh_window_list()
        self._load_window_into_form(self.current_window_index)

    # --- tabs ------------------------------------------------------------

    def _current_tabs(self) -> list[dict]:
        if self.current_window_index is None:
            return []
        return self.windows[self.current_window_index].setdefault("tabs", [])

    def _refresh_tabs_tree(self) -> None:
        self.tabs_tree.delete(*self.tabs_tree.get_children())
        for tab in self._current_tabs():
            self.tabs_tree.insert(
                "",
                tk.END,
                values=(
                    tab["title"],
                    AGENT_BY_KEY.get(tab["agent"], tab["agent"]),
                    tab.get("model", ""),
                    tab.get("effort", ""),
                    tab.get("contextWindow", ""),
                    tab["workingDir"],
                ),
            )
        self._refresh_window_list()

    def _refresh_model_choices(self) -> None:
        agent_key = AGENT_BY_LABEL.get(self.agent_var.get())
        values = MODELS_BY_AGENT.get(agent_key, [""])
        self.model_combo.configure(values=values)
        if self.model_var.get() not in values:
            self.model_var.set(DEFAULT_MODEL_BY_AGENT.get(agent_key, ""))

    def _add_tab(self) -> None:
        title = self.repo_var.get()
        repo = next((r for r in self.repos if r["label"] == title), None)
        if not repo:
            messagebox.showerror("Repo", "Add or select a repository first.")
            return
        agent_label = self.agent_var.get()
        agent_key = AGENT_BY_LABEL.get(agent_label)
        if not agent_key:
            messagebox.showerror("Agent", "Pick a known agent.")
            return
        self._current_tabs().append(
            {
                "title": self.tab_title_var.get().strip() or repo["label"],
                "workingDir": repo["path"],
                "agent": agent_key,
                "model": self.model_var.get().strip(),
                "effort": self.effort_var.get().strip(),
                "contextWindow": self.context_var.get().strip(),
            }
        )
        self.tab_title_var.set("")
        self._refresh_tabs_tree()

    def _edit_tab(self) -> None:
        idx = self._selected_tab_index()
        if idx is None:
            messagebox.showinfo("Edit tab", "Select a tab first.")
            return
        tab = self._current_tabs()[idx]
        dialog = self._toplevel(self, "Edit tab")
        form = ctk.CTkFrame(dialog, fg_color="transparent")
        form.pack(fill=tk.BOTH, expand=True, padx=12, pady=12)
        repo_labels = [repo["label"] for repo in self.repos]
        # Title and working dir are independent - only prefill the repo picker
        # when the path happens to match a catalog entry; don't force one.
        repo_label = next(
            (repo["label"] for repo in self.repos if repo["path"] == tab.get("workingDir")),
            "",
        )
        title_var = tk.StringVar(value=tab.get("title", ""))
        repo_var = tk.StringVar(value=repo_label)
        agent_var = tk.StringVar(value=AGENT_BY_KEY.get(tab.get("agent", ""), AGENTS[0][0]))
        edit_agent_key = AGENT_BY_LABEL.get(agent_var.get())
        model_var = tk.StringVar(
            value=tab.get("model") or DEFAULT_MODEL_BY_AGENT.get(edit_agent_key, "")
        )
        effort_var = tk.StringVar(value=tab.get("effort", ""))
        context_var = tk.StringVar(value=tab.get("contextWindow", "") or CONTEXT_WINDOWS[0])

        self._label(form, "Title", width=110).grid(row=0, column=0, sticky="w", pady=4)
        self._entry(form, title_var, width=280).grid(row=0, column=1, sticky="ew", pady=4)

        self._label(form, "Working dir", width=110).grid(row=1, column=0, sticky="w", pady=4)
        self._label(form, tab.get("workingDir", ""), width=280, muted=True).grid(
            row=1, column=1, sticky="w", pady=4
        )

        self._label(form, "Repo (change dir)", width=110).grid(row=2, column=0, sticky="w", pady=4)
        self._option(form, repo_var, repo_labels or [""], width=280).grid(
            row=2, column=1, sticky="ew", pady=4
        )

        self._label(form, "Agent", width=110).grid(row=3, column=0, sticky="w", pady=4)
        agent_combo = self._option(
            form,
            agent_var,
            [a[0] for a in AGENTS],
            width=280,
            command=lambda _v: refresh_model_values(),
        )
        agent_combo.grid(row=3, column=1, sticky="ew", pady=4)

        self._label(form, "Model", width=110).grid(row=4, column=0, sticky="w", pady=4)
        model_combo = self._combo(form, model_var, CLAUDE_MODELS, width=280)
        model_combo.grid(row=4, column=1, sticky="ew", pady=4)

        def refresh_model_values() -> None:
            agent_key = AGENT_BY_LABEL.get(agent_var.get())
            values = MODELS_BY_AGENT.get(agent_key, [""])
            model_combo.configure(values=values)
            if model_var.get() not in values:
                model_var.set(DEFAULT_MODEL_BY_AGENT.get(agent_key, ""))

        refresh_model_values()

        self._label(form, "Effort", width=110).grid(row=5, column=0, sticky="w", pady=4)
        self._option(form, effort_var, EFFORT_LEVELS, width=280).grid(
            row=5, column=1, sticky="ew", pady=4
        )

        self._label(form, "Context window", width=110).grid(row=6, column=0, sticky="w", pady=4)
        self._option(form, context_var, CONTEXT_WINDOWS, width=280).grid(
            row=6, column=1, sticky="ew", pady=4
        )

        form.columnconfigure(1, weight=1)

        def save() -> None:
            title = title_var.get().strip()
            agent = AGENT_BY_LABEL.get(agent_var.get())
            if not title or not agent:
                messagebox.showerror("Tab", "Title and agent are required.", parent=dialog)
                return
            repo = next((item for item in self.repos if item["label"] == repo_var.get()), None)
            working_dir = repo["path"] if repo else tab.get("workingDir", "")
            tab.update(
                title=title,
                workingDir=working_dir,
                agent=agent,
                model=model_var.get().strip(),
                effort=effort_var.get().strip(),
                contextWindow=context_var.get().strip(),
            )
            self._refresh_tabs_tree()
            children = self.tabs_tree.get_children()
            if idx < len(children):
                self.tabs_tree.selection_set(children[idx])
            dialog.destroy()

        actions = ctk.CTkFrame(form, fg_color="transparent")
        actions.grid(row=7, column=0, columnspan=2, sticky="e", pady=(12, 0))
        self._button(actions, "Save", save).pack(side=tk.LEFT, padx=2)
        self._button(actions, "Cancel", dialog.destroy).pack(side=tk.LEFT, padx=2)

    def _selected_tab_index(self) -> int | None:
        sel = self.tabs_tree.selection()
        if not sel:
            return None
        return self.tabs_tree.index(sel[0])

    def _remove_tab(self) -> None:
        idx = self._selected_tab_index()
        if idx is None:
            return
        tabs = self._current_tabs()
        del tabs[idx]
        self._refresh_tabs_tree()

    def _move_tab(self, delta: int) -> None:
        idx = self._selected_tab_index()
        if idx is None:
            return
        tabs = self._current_tabs()
        new_idx = idx + delta
        if new_idx < 0 or new_idx >= len(tabs):
            return
        tabs[idx], tabs[new_idx] = tabs[new_idx], tabs[idx]
        self._refresh_tabs_tree()
        children = self.tabs_tree.get_children()
        self.tabs_tree.selection_set(children[new_idx])

    # --- launch ----------------------------------------------------------

    def _launch(self, dry_run: bool = False) -> None:
        self._apply_window_settings(silent=True)
        if not any(w.get("tabs") for w in self.windows):
            messagebox.showerror("No tabs", "Add at least one tab before launching.")
            return

        name = self.preset_var.get().strip() or "Untitled"
        # Always write a temp/autosave so launch uses current editor state.
        if name.lower() == "untitled":
            path = PRESETS_DIR / "_scratch.json"
        else:
            path = PRESETS_DIR / f"{name}.json"
        path.write_text(
            json.dumps({"name": name, "windows": self.windows}, indent=2) + "\n",
            encoding="utf-8",
        )
        self._preset_path = path
        self._refresh_preset_list()

        args = [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(INVOKE_PS1),
            "-ConfigPath",
            str(path),
        ]
        if dry_run:
            args.append("-DryRun")

        try:
            proc = subprocess.Popen(args, cwd=str(ROOT))
        except OSError as exc:
            messagebox.showerror("Launch failed", str(exc))
            return

        if dry_run:
            messagebox.showinfo("Dry run", f"Started dry-run (pid {proc.pid}). Check the console.")
        else:
            messagebox.showinfo("Launching", f"Started layout (pid {proc.pid}).")


def main() -> int:
    app = LayoutUI()
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
