---
name: memory-lint
description: Check the file-based memory folder for stale, orphan and contradicting entries, then propose fixes. Use for "/memory-lint", "lint
memory", "clean up memory", "is my memory stale", "prune memories". Reports first and changes nothing until the user approves.
argument-hint: "[memory dir] [--stale-days N]"
---

# memory-lint - find stale and broken memories

The memory folder is an index file plus one markdown file per fact. The index is loaded into every session, so a stale line costs tokens and
misleads. This skill is the lint step: it reports, the user decides, then you apply.

## 1. Run the script

Do not change the working directory. Default memory dir: the one named in the Memory section of your system prompt. The script is
`memory_lint.py` in the base directory of this skill. It needs Python 3.8 or newer and only reads.

```
python "<skill dir>/memory_lint.py" --memory-dir "<memory dir>" --live
```

`--live` compares pull request claims with GitHub through `gh`. Repository aliases and the ticket key pattern come from `<memory dir>/.lint.json`
(`repoAliases`, `ticketPattern`); `lint.example.json` next to the script shows the shape. Without that file the script does the structure and age
checks only. Write the output to the scratchpad when it is long, and read it from there.

## 2. Check ticket status

If the report has a "Ticket keys" section, get the status of those keys from the tracker in as few queries as possible (Jira: one JQL
`key in (...)` search, fields `status` only). A ticket that is Done or Closed while its memory sits under an active heading is stale. If the tracker
call fails, skip this step and say so. Do not retry.

## 3. Judge

The script finds candidates. You decide. For each candidate, read the memory file before you judge it.

- **Contradictions** (memory says open, GitHub says merged or closed; old head): nearly always stale.
- **Mentions of a settled PR**: usually history. Flag one only when the entry as a whole still reads as open work.
- **Old project memories**: ask what a future session would do differently because of this file. If the answer is "nothing", it is a delete.
  Finished-work records (PR merged, ticket closed, nothing owed) are deletes. Keep the non-obvious lesson, if there is one, as a short
  `reference` or `feedback` memory.
- **Durable facts** (domain rules, traps, tool recipes, user preferences) do not go stale by age. Do not flag them for age alone.
- **Not in the index**: add an index line, or delete the file.
- **Not readable PRs**: usually a wrong alias match. Ignore them unless the pattern repeats.

## 4. Check each lesson before you propose it

A lesson that replaces a long note is a new claim, and a summary written from the note alone is often wrong. Check each one two times:

- **Against the source note.** Every statement in the lesson must be in the note. Drop what the note marks as a refuted theory, a plan or a guess.
- **Against the current code.** Read the default branch from its remote ref (`git show origin/<default>:<path>`, `git grep <pattern>
  origin/<default>`),
  not the working tree, which can sit on an old branch. If the code contradicts the lesson, correct the lesson or drop it.

Say which lessons you could not check and why. When there are many, give the checks to subagents in batches and keep their verdicts in a file.

## 5. Report

Give one table, most valuable action first: file, what is wrong (with the live state), proposed action (`delete`, `update: <new text>`,
`shrink to lesson`, `move to closed`, `add to index`). Then one line with the totals and the expected change in index size; a lesson that gets its
own index line makes the index longer, not shorter. Keep it short. Do not list entries that are fine.

## 6. Apply only what the user approves

Change nothing before approval. Then, for the approved rows only:

- Copy each file you delete or shrink to `<memory dir>/../memory-archive/<date>/` first.
- Update the index in the same pass, so no index line points at a missing file.
- Run the script again without `--live` and confirm that the structure section is clean.
