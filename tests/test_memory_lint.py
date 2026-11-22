"""Run from the repo root: python -m unittest discover -s tests"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent / "skills" / "memory-lint"
sys.path.insert(0, str(SKILL_DIR))

import memory_lint  # noqa: E402

NOTE = "---\nname: {name}\ndescription: {name} fact\nmetadata:\n  type: {kind}\n---\n\n{body}\n"


def run_lint(folder: Path, *extra: str) -> str:
    result = subprocess.run(
        [sys.executable, str(SKILL_DIR / "memory_lint.py"), "--memory-dir", str(folder), *extra],
        capture_output=True, text=True, encoding="utf-8", check=True,
    )

    return result.stdout


class StructureTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.folder = Path(self._temp.name)
        self.addCleanup(self._temp.cleanup)

    def write(self, name: str, text: str) -> Path:
        path = self.folder / name
        path.write_text(text, encoding="utf-8")

        return path

    def test_clean_folder_reports_none(self) -> None:
        self.write("MEMORY.md", "- [A](a.md) - hook\n- [B](b.md) - hook\n")
        self.write("a.md", NOTE.format(name="a-fact", kind="reference", body="See [[b-fact]]."))
        self.write("b.md", NOTE.format(name="b-fact", kind="feedback", body="Text."))

        report = run_lint(self.folder)

        self.assertIn("Not in the index (never recalled): none", report)
        self.assertIn("Index links to a missing file: none", report)
        self.assertIn("Missing frontmatter, type or description: none", report)
        self.assertIn("`[[links]]` with no target: none", report)

    def test_structure_problems_are_named(self) -> None:
        self.write("MEMORY.md", "- [A](a.md) - hook\n- [Gone](gone.md) - hook\n")
        self.write("a.md", NOTE.format(name="a-fact", kind="reference", body="See [[missing-fact]]."))
        self.write("orphan.md", "No frontmatter here.\n")

        report = run_lint(self.folder)

        self.assertIn("Not in the index (never recalled): orphan.md", report)
        self.assertIn("Index links to a missing file: gone.md", report)
        self.assertIn("Missing frontmatter, type or description: orphan.md", report)
        self.assertIn("missing-fact (from a.md)", report)

    def test_only_old_project_memories_are_listed_by_age(self) -> None:
        self.write("MEMORY.md", "- [P](p.md)\n- [R](r.md)\n")
        old = time.time() - 90 * 86400
        for name, kind in (("p.md", "project"), ("r.md", "reference")):
            os.utime(self.write(name, NOTE.format(name=name[0], kind=kind, body="Text.")), (old, old))

        section = run_lint(self.folder, "--stale-days", "45").split("## Project memories")[1]

        self.assertIn("- p.md (", section)
        self.assertNotIn("r.md", section)

    def test_config_gives_ticket_keys_and_pr_claims_without_network(self) -> None:
        self.write("MEMORY.md", "- [A](a.md)\n")
        self.write("a.md", NOTE.format(name="a", kind="project", body="PROJ-12 and PROJ-7: backend PR #41 is open."))
        self.write(".lint.json", '{"ticketPattern": "PROJ-\\\\d+", "repoAliases": {"backend": "org/backend"}}')

        report = run_lint(self.folder)

        self.assertIn("## Ticket keys (2)", report)
        self.assertIn("PROJ-12, PROJ-7", report)
        self.assertIn("## Pull request claims (1)", report)
        self.assertIn("Run with --live", report)


class ClaimTests(unittest.TestCase):
    ALIASES = {"app": "org/app", "backend": "org/backend"}

    def claims(self, line: str) -> list[tuple]:
        return [(repo, number, head) for repo, number, _own, _snippet, head, _src in memory_lint.pr_claims("x.md", line, self.ALIASES)]

    def test_nearest_alias_before_the_number_wins(self) -> None:
        self.assertEqual(self.claims("app #10 merged, backend #20 open"), [("org/app", 10, None), ("org/backend", 20, None)])

    def test_number_without_an_alias_is_ignored(self) -> None:
        self.assertEqual(self.claims("see #99 for details"), [])

    def test_head_sha_belongs_to_its_own_pr(self) -> None:
        self.assertEqual(
            self.claims("backend #20 open, head abc1234 pushed; app #10 merged"),
            [("org/backend", 20, "abc1234"), ("org/app", 10, None)],
        )


if __name__ == "__main__":
    unittest.main()
