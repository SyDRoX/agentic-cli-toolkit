"""Run from the repo root: python -m unittest discover -s tests"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import model_catalog  # noqa: E402

# Trimmed from a live GET /v1/models response (2026-10-01).
CLAUDE_PAYLOAD = {
    "data": [
        {"type": "model", "id": "claude-sonnet-5-5", "display_name": "Claude Sonnet 5.5"},
        {"type": "model", "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5"},
        {"type": "model", "id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5"},
    ],
    "has_more": False,
    "first_id": "claude-sonnet-5-5",
    "last_id": "claude-haiku-4-5-20251001",
}

# Trimmed from ~/.codex/models_cache.json (fetched 2026-09-16).
CODEX_CACHE = {
    "fetched_at": "2026-09-16T14:39:03.966737800Z",
    "etag": "x",
    "client_version": "x",
    "models": [
        {"slug": "gpt-5.6-terra", "visibility": "list", "priority": 7},
        {"slug": "gpt-6-astra", "visibility": "list", "priority": 1},
        {"slug": "gpt-reserve", "visibility": "hide", "priority": 3},
        {"slug": "gpt-5.6-sol", "visibility": "list", "priority": 4},
        {"slug": "codex-auto-review", "visibility": "hide", "priority": 43},
    ],
}

# Shape read by launchers/launch-pi.ps1 (Get-PiModelInfo): provider -> {models: [{id}]}.
PI_STORE = {
    "openrouter": {"models": [{"id": "tencent/hy4-preview"}, {"id": "gpt-5.6-luna"}]},
    "openai-codex": {"models": [{"id": "gpt-5.6-luna", "contextWindow": 272000}, {"id": "gpt-6-luna"}]},
    "anthropic": {"models": [{"id": "claude-opus-5-5"}]},
}

FALLBACK = {"claude": ["", "opus"], "codex": ["", "gpt-5.5"], "pi": ["", "gpt-5.6-luna"]}


def _fail() -> list[str]:
    raise OSError("offline")


class ParserTests(unittest.TestCase):
    def test_claude_aliases_lead_then_api_order(self) -> None:
        self.assertEqual(
            model_catalog.parse_claude_models(CLAUDE_PAYLOAD),
            ["opus", "sonnet", "fable", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5-20251001"],
        )

    def test_claude_empty_raises(self) -> None:
        with self.assertRaises(ValueError):
            model_catalog.parse_claude_models({"data": []})

    def test_codex_keeps_visible_sorted_by_priority(self) -> None:
        self.assertEqual(
            model_catalog.parse_codex_cache(CODEX_CACHE), ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"]
        )

    def test_pi_anthropic_then_openai_first_and_qualifies_only_shared_ids(self) -> None:
        self.assertEqual(
            model_catalog.parse_pi_store(PI_STORE),
            [
                "claude-opus-5-5",
                "openai-codex/gpt-5.6-luna",
                "gpt-6-luna",
                "tencent/hy4-preview",
                "openrouter/gpt-5.6-luna",
            ],
        )

    def test_pi_empty_raises(self) -> None:
        with self.assertRaises(ValueError):
            model_catalog.parse_pi_store({"openrouter": {"models": []}})


CATALOG = [f"model-{i:02d}" for i in range(30)] + ["claude-opus-5-5", "gpt-5.6-sol-pro"]


class ListingTests(unittest.TestCase):
    def test_top_is_default_plus_ten(self) -> None:
        top = model_catalog.top_models(CATALOG)
        self.assertEqual(top[0], "")
        self.assertEqual(top[1:], CATALOG[:10])

    def test_recent_leads_and_is_deduped(self) -> None:
        top = model_catalog.top_models(CATALOG, recent=["model-05", "typed-custom"])
        self.assertEqual(top[:4], ["", "model-05", "typed-custom", "model-00"])
        self.assertEqual(len(top), 11)
        self.assertEqual(top.count("model-05"), 1)

    def test_filter_searches_beyond_top_ten(self) -> None:
        self.assertEqual(model_catalog.filter_models(CATALOG, "opus"), ["claude-opus-5-5"])

    def test_filter_needs_every_word_case_insensitive(self) -> None:
        self.assertEqual(model_catalog.filter_models(CATALOG, "SOL pro"), ["gpt-5.6-sol-pro"])
        self.assertEqual(model_catalog.filter_models(CATALOG, "sol opus"), [])

    def test_filter_prefix_matches_first_and_capped(self) -> None:
        hits = model_catalog.filter_models(["x-model", "model-a"] + CATALOG, "model")
        self.assertEqual(hits[0], "model-a")
        self.assertEqual(len(hits), 10)

    def test_filter_blank_query_is_top(self) -> None:
        self.assertEqual(model_catalog.filter_models(CATALOG, "  "), model_catalog.top_models(CATALOG))

    def test_remember_moves_to_front_and_caps(self) -> None:
        recent = ["a", "b", "c", "d", "e"]
        self.assertEqual(model_catalog.remember_model(recent, "c"), ["c", "a", "b", "d", "e"])
        self.assertEqual(model_catalog.remember_model(recent, "f"), ["f", "a", "b", "c", "d"])
        self.assertEqual(model_catalog.remember_model(recent, ""), recent)


class ResolveTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self._tmp.name) / ".model-cache.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_cache(self, fetched_at: float) -> None:
        self.cache.write_text(
            json.dumps({agent: {"fetchedAt": fetched_at, "models": [f"{agent}-cached"]} for agent in FALLBACK}),
            encoding="utf-8",
        )

    def test_no_cache_and_fetch_fails_gives_constants(self) -> None:
        result = model_catalog.resolve_models(self.cache, FALLBACK, fetchers={a: _fail for a in FALLBACK})
        self.assertEqual(result, FALLBACK)
        self.assertFalse(self.cache.exists())

    def test_fetch_failure_falls_back_to_stale_cache(self) -> None:
        self._write_cache(fetched_at=0)
        result = model_catalog.resolve_models(self.cache, FALLBACK, fetchers={a: _fail for a in FALLBACK})
        self.assertEqual(result["codex"], ["", "codex-cached"])

    def test_fresh_fetch_is_cached_with_default_entry(self) -> None:
        fetchers = {a: (lambda a=a: [f"{a}-live"]) for a in FALLBACK}
        result = model_catalog.resolve_models(self.cache, FALLBACK, fetchers=fetchers, now=lambda: 1000.0)
        self.assertEqual(result["pi"], ["", "pi-live"])
        stored = json.loads(self.cache.read_text(encoding="utf-8"))
        self.assertEqual(stored["pi"], {"fetchedAt": 1000.0, "models": ["pi-live"]})

    def test_fresh_cache_skips_fetch_unless_forced(self) -> None:
        self._write_cache(fetched_at=1000.0)
        calls: list[str] = []

        def live(agent: str) -> list[str]:
            calls.append(agent)
            return [f"{agent}-live"]

        fetchers = {a: (lambda a=a: live(a)) for a in FALLBACK}
        result = model_catalog.resolve_models(self.cache, FALLBACK, fetchers=fetchers, now=lambda: 1001.0)
        self.assertEqual(result["claude"], ["", "claude-cached"])
        self.assertEqual(calls, [])

        result = model_catalog.resolve_models(
            self.cache, FALLBACK, fetchers=fetchers, now=lambda: 1001.0, is_forced=True
        )
        self.assertEqual(result["claude"], ["", "claude-live"])
        self.assertEqual(sorted(calls), sorted(FALLBACK))

    def test_offline_never_fetches(self) -> None:
        fetchers = {a: (lambda: self.fail("fetched while offline")) for a in FALLBACK}
        result = model_catalog.resolve_models(self.cache, FALLBACK, fetchers=fetchers, is_offline=True)
        self.assertEqual(result, FALLBACK)

    def test_corrupt_cache_is_ignored(self) -> None:
        self.cache.write_text("{not json", encoding="utf-8")
        result = model_catalog.resolve_models(self.cache, FALLBACK, fetchers={a: _fail for a in FALLBACK})
        self.assertEqual(result, FALLBACK)


if __name__ == "__main__":
    unittest.main()
