"""Brand tokens for the Dev Layout Composer (appearance mode follows the OS at launch).

Ported from skillreal-station-updater's deployer_ui/theme.py. customtkinter's built-in
light/dark palette only swaps its own default widget colors, so every role hex lives here
once and widgets apply resolve_color() for the launch-detected OS mode. An unknown role
raises rather than resolving to a silent default.

The classic-Tk holdouts (tk.Listbox, ttk.Treeview) have no customtkinter equivalent, so
style_treeview() and listbox_kwargs() paint them from the same table.
"""

from __future__ import annotations

import ctypes
import sys
import tkinter as tk
from tkinter import ttk

import customtkinter

# (dark_hex, light_hex) per role. Tk has no alpha compositing, so each tint is a solid.
_TOKENS: dict[str, tuple[str, str]] = {
    "frame": ("#161b23", "#ffffff"),
    "panel": ("#1c222c", "#f0f3f7"),
    "chrome": ("#131a24", "#e7ebf1"),
    "accent": ("#E06800", "#D06000"),
    "accent_hover": ("#C05800", "#B05000"),
    "accent_text": ("#ffffff", "#ffffff"),
    "err": ("#cf4a3a", "#b83020"),
    "ok": ("#3fa860", "#2a7d40"),
    "warn": ("#d9a521", "#a07810"),
    "line": ("#2a323e", "#d5dae2"),
    "separator": ("#36404d", "#dde2ea"),
    "text": ("#e8e6e2", "#18202b"),
    "muted": ("#98a0ab", "#586170"),
    "dim": ("#69717c", "#8a94a2"),
    "surface": ("#0d0f12", "#f8f7f4"),
    "button": ("#2a323e", "#e2e6ec"),
    "button_hover": ("#36404d", "#d2d8e1"),
}

_MODE_INDEX: dict[str, int] = {"dark": 0, "light": 1}

# Stock Tk fonts expose only "normal"/"bold".
FONT_BODY: tuple[str, int] = ("Segoe UI", 12)
FONT_LABEL: tuple[str, int, str] = ("Segoe UI", 11, "bold")
FONT_HEADING: tuple[str, int, str] = ("Segoe UI", 13, "bold")
FONT_MONO: tuple[str, int] = ("Consolas", 11)


def resolve_color(role: str, mode: str) -> str:
    """Return the dark or light hex for role; raise on either an unknown mode or role."""
    if mode not in _MODE_INDEX:
        raise ValueError(f"unknown appearance mode {mode!r} (expected 'dark' or 'light')")
    return _TOKENS[role][_MODE_INDEX[mode]]


def apply_appearance_mode(mode: str) -> None:
    customtkinter.set_appearance_mode(mode)


def detect_os_mode() -> str:
    # customtkinter starts in "System" mode, so get_appearance_mode() reports the OS value.
    return customtkinter.get_appearance_mode().lower()


def listbox_kwargs(mode: str) -> dict[str, object]:
    """Constructor kwargs that paint a classic tk.Listbox with the token palette."""
    return {
        "background": resolve_color("surface", mode),
        "foreground": resolve_color("text", mode),
        "selectbackground": resolve_color("accent", mode),
        "selectforeground": resolve_color("accent_text", mode),
        "highlightthickness": 1,
        "highlightbackground": resolve_color("line", mode),
        "highlightcolor": resolve_color("accent", mode),
        "borderwidth": 0,
        "relief": tk.FLAT,
        "activestyle": "none",
        "font": FONT_BODY,
    }


def style_treeview(mode: str) -> None:
    """Repaint ttk.Treeview globally; ttk theme must be 'clam' for colors to take effect."""
    style = ttk.Style()
    # The native "vista"/"xpnative" themes ignore background/fieldbackground entirely.
    style.theme_use("clam")
    style.configure(
        "Treeview",
        background=resolve_color("surface", mode),
        fieldbackground=resolve_color("surface", mode),
        foreground=resolve_color("text", mode),
        bordercolor=resolve_color("line", mode),
        borderwidth=0,
        rowheight=24,
        font=FONT_BODY,
    )
    style.configure(
        "Treeview.Heading",
        background=resolve_color("panel", mode),
        foreground=resolve_color("muted", mode),
        relief=tk.FLAT,
        font=FONT_LABEL,
    )
    style.map(
        "Treeview",
        background=[("selected", resolve_color("accent", mode))],
        foreground=[("selected", resolve_color("accent_text", mode))],
    )
    style.map(
        "Treeview.Heading",
        background=[("active", resolve_color("button_hover", mode))],
    )
    # clam draws a raised 3-D border around the scrollbar trough otherwise.
    style.configure(
        "Vertical.TScrollbar",
        background=resolve_color("button", mode),
        troughcolor=resolve_color("panel", mode),
        bordercolor=resolve_color("panel", mode),
        arrowcolor=resolve_color("muted", mode),
        relief=tk.FLAT,
    )


def apply_titlebar_color(window: tk.Misc, mode: str) -> None:
    """Repaint a window's Windows titlebar to match mode.

    customtkinter does this for CTkToplevel in __init__, but it reads the HWND before Tk has
    mapped the window, so the attribute lands on the wrong handle and the bar stays light.
    Call this once the window is on screen.
    """
    if not sys.platform.startswith("win"):
        return
    window.update_idletasks()
    value = ctypes.c_int(1 if mode == "dark" else 0)
    hwnd = ctypes.windll.user32.GetParent(window.winfo_id())
    # 20 is DWMWA_USE_IMMERSIVE_DARK_MODE; 19 is its pre-20H1 spelling.
    for attribute in (20, 19):
        if ctypes.windll.dwmapi.DwmSetWindowAttribute(
            hwnd, attribute, ctypes.byref(value), ctypes.sizeof(value)
        ) == 0:
            return
