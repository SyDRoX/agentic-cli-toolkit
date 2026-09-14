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

ROOT = Path(__file__).resolve().parent
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


class LayoutUI(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Dev Layout Composer")
        self.geometry("920x640")
        self.minsize(800, 520)

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

    def _build(self) -> None:
        top = ttk.Frame(self, padding=8)
        top.pack(fill=tk.X)

        ttk.Label(top, text="Preset").pack(side=tk.LEFT)
        self.preset_combo = ttk.Combobox(top, textvariable=self.preset_var, width=28)
        self.preset_combo.pack(side=tk.LEFT, padx=(6, 4))
        self.preset_combo.bind("<<ComboboxSelected>>", lambda _e: self._load_selected_preset())

        ttk.Button(top, text="New", command=self._new_preset).pack(side=tk.LEFT, padx=2)
        ttk.Button(top, text="Load", command=self._browse_load_preset).pack(side=tk.LEFT, padx=2)
        ttk.Button(top, text="Save", command=self._save_preset).pack(side=tk.LEFT, padx=2)
        ttk.Button(top, text="Delete", command=self._delete_preset).pack(side=tk.LEFT, padx=2)
        ttk.Button(top, text="Repos...", command=self._manage_repos).pack(side=tk.LEFT, padx=(12, 2))
        ttk.Button(top, text="Launch", command=self._launch).pack(side=tk.RIGHT, padx=2)
        ttk.Button(top, text="Dry run", command=lambda: self._launch(dry_run=True)).pack(
            side=tk.RIGHT, padx=2
        )

        body = ttk.Frame(self, padding=8)
        body.pack(fill=tk.BOTH, expand=True)

        windows_frame = ttk.LabelFrame(body, text="Terminal windows", padding=4)
        windows_frame.pack(fill=tk.X, pady=(0, 8))

        self.window_list = tk.Listbox(windows_frame, exportselection=False, height=6)
        self.window_list.pack(fill=tk.X, expand=True, pady=4)
        self.window_list.bind("<<ListboxSelect>>", lambda _e: self._on_select_window())
        self.window_list.bind("<Delete>", lambda _e: self._remove_window())

        win_btns = ttk.Frame(windows_frame)
        win_btns.pack(fill=tk.X)
        ttk.Button(win_btns, text="Add window", command=self._add_window).pack(
            side=tk.LEFT, padx=2
        )
        ttk.Button(win_btns, text="Remove", command=self._remove_window).pack(
            side=tk.LEFT, padx=2
        )

        right = ttk.Frame(body)
        right.pack(fill=tk.BOTH, expand=True)

        form = ttk.LabelFrame(right, text="Selected window", padding=8)
        form.pack(fill=tk.X)

        row = ttk.Frame(form)
        row.pack(fill=tk.X, pady=2)
        ttk.Label(row, text="Name", width=12).pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=self.window_name_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        row = ttk.Frame(form)
        row.pack(fill=tk.X, pady=2)
        ttk.Label(row, text="Monitor", width=12).pack(side=tk.LEFT)
        ttk.Spinbox(row, from_=0, to=3, textvariable=self.monitor_var, width=6).pack(
            side=tk.LEFT
        )
        ttk.Label(row, text="(0 = leftmost)").pack(side=tk.LEFT, padx=6)

        row = ttk.Frame(form)
        row.pack(fill=tk.X, pady=2)
        ttk.Label(row, text="Window slot", width=12).pack(side=tk.LEFT)
        ttk.Spinbox(row, from_=SLOT_START, to=999, textvariable=self.window_num_var, width=6).pack(
            side=tk.LEFT
        )
        ttk.Label(row, text="keep stable for session resume").pack(side=tk.LEFT, padx=6)

        ttk.Button(form, text="Apply window settings", command=self._apply_window_settings).pack(
            anchor=tk.E, pady=(6, 0)
        )

        tabs_frame = ttk.LabelFrame(right, text="Tabs (repo + agent)", padding=8)
        tabs_frame.pack(fill=tk.BOTH, expand=True, pady=(8, 0))

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
        self.tabs_tree.column("effort", width=60, stretch=False)
        self.tabs_tree.column("context", width=100, stretch=False)
        self.tabs_tree.column("path", width=280)
        self.tabs_tree.pack(fill=tk.BOTH, expand=True)
        self.tabs_tree.bind("<Double-1>", lambda _e: self._edit_tab())
        self.tabs_tree.bind("<Delete>", lambda _e: self._remove_tab())

        fields_row = ttk.Frame(tabs_frame)
        fields_row.pack(fill=tk.X, pady=(8, 0))

        ttk.Label(fields_row, text="Repo").pack(side=tk.LEFT)
        self.repo_combo = ttk.Combobox(
            fields_row,
            textvariable=self.repo_var,
            values=[r["label"] for r in self.repos],
            state="readonly",
            width=12,
        )
        self.repo_combo.pack(side=tk.LEFT, padx=4)

        ttk.Label(fields_row, text="Title").pack(side=tk.LEFT, padx=(8, 0))
        ttk.Entry(fields_row, textvariable=self.tab_title_var, width=12).pack(side=tk.LEFT, padx=4)

        ttk.Label(fields_row, text="Agent").pack(side=tk.LEFT, padx=(8, 0))
        self.agent_combo = ttk.Combobox(
            fields_row,
            textvariable=self.agent_var,
            values=[a[0] for a in AGENTS],
            state="readonly",
            width=12,
        )
        self.agent_combo.pack(side=tk.LEFT, padx=4)
        self.agent_combo.bind("<<ComboboxSelected>>", lambda _e: self._refresh_model_choices())

        ttk.Label(fields_row, text="Model").pack(side=tk.LEFT, padx=(8, 0))
        self.model_combo = ttk.Combobox(fields_row, textvariable=self.model_var, width=16)
        self.model_combo.pack(side=tk.LEFT, padx=4)

        ttk.Label(fields_row, text="Effort").pack(side=tk.LEFT, padx=(8, 0))
        ttk.Combobox(
            fields_row, textvariable=self.effort_var, values=EFFORT_LEVELS, state="readonly", width=8
        ).pack(side=tk.LEFT, padx=4)

        ttk.Label(fields_row, text="Context window").pack(side=tk.LEFT, padx=(8, 0))
        ttk.Combobox(
            fields_row, textvariable=self.context_var, values=CONTEXT_WINDOWS, state="readonly", width=8
        ).pack(side=tk.LEFT, padx=4)

        add_row = ttk.Frame(tabs_frame)
        add_row.pack(fill=tk.X, pady=(4, 0))

        ttk.Button(add_row, text="Add tab", command=self._add_tab).pack(side=tk.LEFT, padx=4)
        ttk.Button(add_row, text="Edit tab", command=self._edit_tab).pack(side=tk.LEFT, padx=2)
        ttk.Button(add_row, text="Remove tab", command=self._remove_tab).pack(side=tk.LEFT)
        ttk.Button(add_row, text="Move up", command=lambda: self._move_tab(-1)).pack(
            side=tk.LEFT, padx=4
        )
        ttk.Button(add_row, text="Move down", command=lambda: self._move_tab(1)).pack(
            side=tk.LEFT
        )

        hint = ttk.Label(
            self,
            text="Example: Window1 [PS-1 Pi] [PS-2 Codex] [ORMI-1 Cursor]  ·  "
            "Window2 [ORMI-1 Claude] [ORMI-2 Codex] [ORMI-3 Cursor]",
            padding=(8, 0, 8, 8),
        )
        hint.pack(fill=tk.X)

    # --- preset CRUD -----------------------------------------------------

    def _refresh_preset_list(self) -> None:
        names = sorted(p.stem for p in PRESETS_DIR.glob("*.json"))
        self.preset_combo["values"] = names

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
        self.repo_combo["values"] = labels
        if labels and self.repo_var.get() not in labels:
            self.repo_var.set(labels[0])
        elif not labels:
            self.repo_var.set("")

    def _manage_repos(self) -> None:
        dialog = tk.Toplevel(self)
        dialog.title("Repository catalog")
        dialog.geometry("620x360")
        dialog.transient(self)

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

        buttons = ttk.Frame(dialog)
        buttons.pack(fill=tk.X, padx=8, pady=(0, 8))
        def add() -> None:
            editor = self._edit_repo_dialog(dialog)
            dialog.wait_window(editor)
            refresh()

        ttk.Button(buttons, text="Add", command=add).pack(side=tk.LEFT, padx=2)

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

        ttk.Button(buttons, text="Edit", command=edit).pack(side=tk.LEFT, padx=2)
        ttk.Button(buttons, text="Remove", command=remove).pack(side=tk.LEFT, padx=2)
        ttk.Button(buttons, text="Close", command=dialog.destroy).pack(side=tk.RIGHT, padx=2)
        tree.bind("<Double-1>", lambda _event: edit())
        refresh()
        dialog.grab_set()

    def _edit_repo_dialog(self, parent: tk.Misc, index: int | None = None) -> tk.Toplevel:
        repo = self.repos[index] if index is not None else {"label": "", "path": ""}
        dialog = tk.Toplevel(parent)
        dialog.title("Edit repository" if index is not None else "Add repository")
        dialog.transient(parent)

        label_var = tk.StringVar(value=repo["label"])
        path_var = tk.StringVar(value=repo["path"])
        form = ttk.Frame(dialog, padding=12)
        form.pack(fill=tk.BOTH, expand=True)
        ttk.Label(form, text="Name", width=14).grid(row=0, column=0, sticky="w", pady=4)
        ttk.Entry(form, textvariable=label_var, width=42).grid(row=0, column=1, columnspan=2, sticky="ew", pady=4)
        ttk.Label(form, text="Working directory", width=14).grid(row=1, column=0, sticky="w", pady=4)
        ttk.Entry(form, textvariable=path_var, width=42).grid(row=1, column=1, sticky="ew", pady=4)

        def browse() -> None:
            chosen = filedialog.askdirectory(parent=dialog, initialdir=path_var.get() or str(ROOT))
            if chosen:
                path_var.set(chosen)

        ttk.Button(form, text="Browse...", command=browse).grid(row=1, column=2, padx=(6, 0))
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

        actions = ttk.Frame(form)
        actions.grid(row=2, column=0, columnspan=3, sticky="e", pady=(12, 0))
        ttk.Button(actions, text="Save", command=save).pack(side=tk.LEFT, padx=2)
        ttk.Button(actions, text="Cancel", command=dialog.destroy).pack(side=tk.LEFT, padx=2)
        dialog.grab_set()
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
        win["name"] = self.window_name_var.get().strip() or win.get("name", "Terminal")
        win["targetMonitor"] = int(self.monitor_var.get())
        win["windowNum"] = int(self.window_num_var.get())
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
        self.model_combo["values"] = MODELS_BY_AGENT.get(agent_key, [""])
        if self.model_var.get() not in self.model_combo["values"]:
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
        dialog = tk.Toplevel(self)
        dialog.title("Edit tab")
        dialog.transient(self)
        form = ttk.Frame(dialog, padding=12)
        form.pack(fill=tk.BOTH, expand=True)
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
        ttk.Label(form, text="Title", width=12).grid(row=0, column=0, sticky="w", pady=4)
        ttk.Entry(form, textvariable=title_var, width=36).grid(row=0, column=1, sticky="ew", pady=4)

        ttk.Label(form, text="Working dir", width=12).grid(row=1, column=0, sticky="w", pady=4)
        ttk.Label(form, text=tab.get("workingDir", ""), width=36).grid(row=1, column=1, sticky="w", pady=4)

        ttk.Label(form, text="Repo (change dir)", width=12).grid(row=2, column=0, sticky="w", pady=4)
        ttk.Combobox(form, textvariable=repo_var, values=repo_labels, state="readonly", width=34).grid(
            row=2, column=1, sticky="ew", pady=4
        )
        ttk.Label(form, text="Agent", width=12).grid(row=3, column=0, sticky="w", pady=4)
        agent_combo = ttk.Combobox(
            form, textvariable=agent_var, values=[a[0] for a in AGENTS], state="readonly", width=34
        )
        agent_combo.grid(row=3, column=1, sticky="ew", pady=4)

        ttk.Label(form, text="Model", width=12).grid(row=4, column=0, sticky="w", pady=4)
        model_combo = ttk.Combobox(form, textvariable=model_var, width=34)
        model_combo.grid(row=4, column=1, sticky="ew", pady=4)

        def refresh_model_values() -> None:
            agent_key = AGENT_BY_LABEL.get(agent_var.get())
            model_combo["values"] = MODELS_BY_AGENT.get(agent_key, [""])
            if model_var.get() not in model_combo["values"]:
                model_var.set(DEFAULT_MODEL_BY_AGENT.get(agent_key, ""))

        agent_combo.bind("<<ComboboxSelected>>", lambda _e: refresh_model_values())
        refresh_model_values()

        ttk.Label(form, text="Effort", width=12).grid(row=5, column=0, sticky="w", pady=4)
        ttk.Combobox(form, textvariable=effort_var, values=EFFORT_LEVELS, state="readonly", width=34).grid(
            row=5, column=1, sticky="ew", pady=4
        )

        ttk.Label(form, text="Context window", width=14).grid(row=6, column=0, sticky="w", pady=4)
        ttk.Combobox(
            form, textvariable=context_var, values=CONTEXT_WINDOWS, state="readonly", width=34
        ).grid(row=6, column=1, sticky="ew", pady=4)

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

        actions = ttk.Frame(form)
        actions.grid(row=7, column=0, columnspan=2, sticky="e", pady=(12, 0))
        ttk.Button(actions, text="Save", command=save).pack(side=tk.LEFT, padx=2)
        ttk.Button(actions, text="Cancel", command=dialog.destroy).pack(side=tk.LEFT, padx=2)
        dialog.grab_set()

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
