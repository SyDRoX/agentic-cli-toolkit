"""Live model lists for the layout composer, read from each CLI's own catalog.

UI-free on purpose: layout_ui.py owns every widget, this module only returns lists.
"""

from __future__ import annotations

import json
import os
import time
import urllib.request
from pathlib import Path
from typing import Callable

CACHE_TTL_SECONDS = 24 * 3600
CLAUDE_MODELS_URL = "https://api.anthropic.com/v1/models?limit=100"
CLAUDE_ALIASES = ["opus", "sonnet", "fable"]
CLAUDE_CREDENTIALS = Path.home() / ".claude" / ".credentials.json"
CODEX_CACHE = Path.home() / ".codex" / "models_cache.json"
PI_STORE = Path.home() / ".pi" / "agent" / "models-store.json"


def parse_claude_models(payload: dict) -> list[str]:
    ids = [m["id"] for m in payload.get("data", []) if isinstance(m, dict) and m.get("id")]
    if not ids:
        raise ValueError("no Claude models in response")
    return CLAUDE_ALIASES + [i for i in ids if i not in CLAUDE_ALIASES]


def _claude_headers() -> dict[str, str]:
    headers = {"anthropic-version": "2023-06-01"}
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if api_key:
        headers["x-api-key"] = api_key
        return headers

    oauth = json.loads(CLAUDE_CREDENTIALS.read_text(encoding="utf-8"))["claudeAiOauth"]
    # The CLI refreshes the token; an expired one would only earn a 401, so skip the request.
    if oauth.get("expiresAt") and oauth["expiresAt"] / 1000 < time.time():
        raise PermissionError("Claude OAuth token expired")
    headers["Authorization"] = f"Bearer {oauth['accessToken']}"
    headers["anthropic-beta"] = "oauth-2025-04-20"
    return headers


def fetch_claude(timeout_seconds: float = 10) -> list[str]:
    request = urllib.request.Request(CLAUDE_MODELS_URL, headers=_claude_headers())
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        return parse_claude_models(json.load(response))


def parse_codex_cache(data: dict) -> list[str]:
    visible = [m for m in data.get("models", []) if m.get("visibility") == "list" and m.get("slug")]
    if not visible:
        raise ValueError("no visible Codex models in cache")
    visible.sort(key=lambda m: m.get("priority", 0))
    return [m["slug"] for m in visible]


def fetch_codex(path: Path = CODEX_CACHE) -> list[str]:
    return parse_codex_cache(json.loads(path.read_text(encoding="utf-8")))


def parse_pi_store(store: dict) -> list[str]:
    pairs = [
        (provider, m["id"])
        for provider, entry in store.items()
        if isinstance(entry, dict)
        for m in entry.get("models", [])
        if isinstance(m, dict) and m.get("id")
    ]
    if not pairs:
        raise ValueError("no pi models in store")
    counts: dict[str, int] = {}
    for _provider, model_id in pairs:
        counts[model_id] = counts.get(model_id, 0) + 1
    # pi's --model takes a bare id; qualify only the ids several providers share.
    names = [model_id if counts[model_id] == 1 else f"{provider}/{model_id}" for provider, model_id in pairs]
    return list(dict.fromkeys(names))


def fetch_pi(path: Path = PI_STORE) -> list[str]:
    return parse_pi_store(json.loads(path.read_text(encoding="utf-8")))


FETCHERS: dict[str, Callable[[], list[str]]] = {
    "claude": fetch_claude,
    "codex": fetch_codex,
    "pi": fetch_pi,
}


def _load_cache(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_cache(path: Path, cache: dict) -> None:
    try:
        path.write_text(json.dumps(cache, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def resolve_models(
    cache_path: Path,
    fallback: dict[str, list[str]],
    *,
    is_offline: bool = False,
    is_forced: bool = False,
    fetchers: dict[str, Callable[[], list[str]]] = FETCHERS,
    now: Callable[[], float] = time.time,
) -> dict[str, list[str]]:
    """Per agent: fresh fetch, else cached list of any age, else the fallback constant.

    Every list keeps a leading "" (CLI default) so the dropdown is never empty.
    """
    cache = _load_cache(cache_path)
    is_cache_changed = False
    result: dict[str, list[str]] = {}
    for agent, constant in fallback.items():
        entry = cache.get(agent) if isinstance(cache.get(agent), dict) else None
        cached = entry.get("models") if entry else None
        is_fresh = bool(entry) and now() - entry.get("fetchedAt", 0) < CACHE_TTL_SECONDS
        models = cached
        if not is_offline and agent in fetchers and (is_forced or not is_fresh):
            try:
                models = fetchers[agent]()
                cache[agent] = {"fetchedAt": now(), "models": models}
                is_cache_changed = True
            except Exception:
                models = cached
        result[agent] = [""] + [m for m in models if m] if models else list(constant)
    if is_cache_changed:
        _save_cache(cache_path, cache)
    return result
