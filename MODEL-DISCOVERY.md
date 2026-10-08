# Dynamic model lists for the layout composer

Goal: stop hand-editing `CLAUDE_MODELS` / `CODEX_MODELS` / `PI_MODELS` in `layout_ui.py`
every time a model ships. Each CLI already exposes its own live catalog; read those.

**Status: implemented 2026-10-01** in `model_catalog.py` + `layout_ui.py`, tests in `tests/test_model_catalog.py`.
Deviation: pi reads `~/.pi/agent/models-store.json` instead of `pi --list-models` (see the Pi row).
Added after: the dropdown shows only 10 entries (last-used first, then catalog order) and typing searches the full
catalog, because the pi store can hold hundreds of OpenRouter models.

## Sources (verified 2026-09-30 on this machine)

| Agent | Source | Notes |
|-------|--------|-------|
| Claude | `GET https://api.anthropic.com/v1/models?limit=100` | Auth: `x-api-key: $ANTHROPIC_API_KEY` if set; else `Authorization: Bearer <claudeAiOauth.accessToken>` from `~/.claude/.credentials.json` plus header `anthropic-beta: oauth-2025-04-20`. Also send `anthropic-version: 2023-06-01`. Returned 13 ids, newest first, account-scoped (includes `claude-opus-5-5`, `claude-sonnet-5-5`). |
| Codex | `~/.codex/models_cache.json` (read as UTF-8) | `{fetched_at, etag, client_version, models:[...]}`. Keep `visibility == "list"`, sort by `priority`. Each entry has `slug`, `display_name`, `context_window`, `max_context_window`, `supported_reasoning_levels` - can also drive the context/effort combos. Codex refreshes the file itself. |
| Pi | `~/.pi/agent/models-store.json` | `{<provider>: {models: [{id, ...}]}}`, the shape `launch-pi.ps1` already parses. Ids are bare unless several providers share one, then `provider/id`. Chosen over `pi --list-models`, whose output was unverifiable (pi not installed here). Unverified against a real store: confirm the provider names match the `anthropic` / `openai` prefixes on a pi machine. |

Rejected: scraping model ids out of the `claude` binary (`grep -a -o '"claude-...'`). Instant and offline, but returns retired ids
(`claude-sonnet-3-7`) and depends on binary layout.

## Risk

OAuth bearer access to `/v1/models` works today but is not a documented third-party path. `ANTHROPIC_API_KEY` is the supported route. Either way the
fallback chain below keeps the UI working.

## Design

1. New `model_catalog.py` beside `layout_ui.py`: one fetcher per agent, each returning `list[str]` or raising.
2. Cache results in `.model-cache.json` beside the script/exe (gitignore it), keyed by agent, with a fetch timestamp. TTL 24h.
3. Resolution per agent: fresh fetch -> cached list (any age) -> current hardcoded constant. Dropdown is never empty.
4. Claude list: aliases `opus`, `sonnet`, `fable` first, then API ids in API order. Keep leading `""` (CLI default) for every agent.
5. `layout_ui.py`: populate combos from the hardcoded lists immediately, fetch in a background thread at startup, then update combo values on the Tk
   main thread (`after(0, ...)`). Add a "Refresh models" button that bypasses the TTL.
6. Combos stay editable: typing an unlisted id must still work.
7. No change to `Invoke-CustomLayout.ps1` or presets; `model` stays a plain string.
8. Colors only via `ui_theme.resolve_color()`; single-file UI rule applies to `layout_ui.py`, so `model_catalog.py` must stay UI-free.
9. `LayoutUI.spec` / `Build-LayoutUI.ps1`: make sure PyInstaller bundles `model_catalog.py` (it is imported, so it should be picked up; verify with a
   rebuilt exe).

## Tests

- Fetchers against canned inputs: sample `/v1/models` JSON, a `models_cache.json` fixture copied from the real file (trimmed), a pi `models-store.json` in the
  shape `launch-pi.ps1` reads.
- Fallback: network error -> cache; no cache -> constants.
- Manual: launch UI offline and online; confirm `claude-opus-5-5` appears without editing code.
