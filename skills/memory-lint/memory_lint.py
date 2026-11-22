"""Lint a file-based agent memory folder: one index file plus one markdown file per fact.

Read-only. Prints a markdown report. Works on any folder of this shape, for any agent.
"""
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time

INDEX_LINK = re.compile(r"\]\(([^)#]+\.md)\)")
WIKI_LINK = re.compile(r"\[\[([^\]|]+)")
HEAD_SHA = re.compile(r"\bhead\s+`?([0-9a-f]{7,40})\b", re.I)
SETTLED = re.compile(r"merged|closed|done|abandon|superseded|dropped|fixed by|shipped|reverted", re.I)
PENDING = re.compile(r"\bopen\b|draft|owed|pushed|unmerged|pending|competing|\bhead\b", re.I)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def frontmatter(text):
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end < 0:
        return None
    block = text[3:end]
    name = re.search(r"^name:\s*(.+)$", block, re.M)
    kind = re.search(r"^\s*type:\s*(\w+)", block, re.M)
    desc = re.search(r"^description:\s*(.+)$", block, re.M)
    return {
        "name": name.group(1).strip().strip("\"'") if name else "",
        "type": kind.group(1) if kind else "",
        "description": desc.group(1).strip() if desc else "",
    }


def find_gh():
    found = shutil.which("gh")
    if found:
        return found
    fallback = os.path.join(os.environ.get("ProgramFiles", ""), "GitHub CLI", "gh.exe")
    return fallback if os.path.exists(fallback) else None


def pr_state(gh, repo, number):
    try:
        out = subprocess.run(
            [gh, "pr", "view", str(number), "--repo", repo, "--json", "state,headRefOid,mergedAt,closedAt"],
            capture_output=True, text=True, timeout=40, stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)}
    if out.returncode != 0:
        return {"error": (out.stderr or out.stdout).strip().splitlines()[-1][:120] if (out.stderr or out.stdout).strip() else "gh failed"}
    return json.loads(out.stdout)


def pr_claims(source, text, aliases):
    """Yield (repo, number, snippet, claimed head) for each '<alias> ... #N' in the text."""
    if not aliases:
        return
    words = "|".join(sorted((re.escape(a) for a in aliases), key=len, reverse=True))
    ref = re.compile(r"#(\d{1,5})\b")
    alias_at = re.compile(r"\b(" + words + r")\b", re.I)
    for line in text.splitlines():
        marks = [(m.start(), aliases[m.group(1).lower()]) for m in alias_at.finditer(line)]
        previous_end = 0
        for match in ref.finditer(line):
            lead_start, previous_end = max(previous_end, match.start() - 45), match.end()
            before = [repo for pos, repo in marks if pos < match.start() and match.start() - pos <= 60]
            if not before:
                continue
            tail = line[match.end():match.end() + 90]
            # The claim about this PR starts after the previous PR reference or sentence break and ends where the next one begins.
            nxt = ref.search(tail)
            lead = re.split(r";|\. ", line[lead_start:match.start()])[-1]
            own = lead + " " + (tail[:nxt.start()] if nxt else tail)
            head = HEAD_SHA.search(own)
            snippet = line[max(0, match.start() - 30):match.end() + 60].strip()
            yield before[-1], int(match.group(1)), own, snippet, head.group(1).lower() if head else None, source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--memory-dir", required=True)
    parser.add_argument("--index", default="MEMORY.md")
    parser.add_argument("--config", help="JSON with repoAliases and ticketPattern; default <memory-dir>/.lint.json")
    parser.add_argument("--stale-days", type=int, default=45)
    parser.add_argument("--live", action="store_true", help="compare PR claims with GitHub through gh")
    args = parser.parse_args()

    sys.stdout.reconfigure(encoding="utf-8")
    root = args.memory_dir
    index_path = os.path.join(root, args.index)
    if not os.path.isfile(index_path):
        sys.exit(f"No index file: {index_path}")

    config_path = args.config or os.path.join(root, ".lint.json")
    config = json.loads(read(config_path)) if os.path.isfile(config_path) else {}
    aliases = {k.lower(): v for k, v in config.get("repoAliases", {}).items()}
    ticket_re = re.compile(config["ticketPattern"]) if config.get("ticketPattern") else None

    index = read(index_path)
    files = sorted(f for f in os.listdir(root) if f.endswith(".md") and f != args.index)
    linked = {os.path.basename(p) for p in INDEX_LINK.findall(index) if "/" not in p and "\\" not in p}
    now = time.time()

    meta, names = {}, set()
    for name in files:
        text = read(os.path.join(root, name))
        fm = frontmatter(text)
        meta[name] = {"text": text, "fm": fm, "age": int((now - os.path.getmtime(os.path.join(root, name))) / 86400)}
        names.add(name[:-3])
        if fm and fm["name"]:
            names.add(fm["name"])
            names.add(fm["name"].replace("-", "_"))

    print(f"# Memory lint: {root}\n")
    print(f"- Files: {len(files)}; index: {len(index.splitlines())} lines, {len(index)} characters (loaded in every session)")

    orphans = [f for f in files if f not in linked]
    dead = sorted(p for p in linked if p not in meta)
    no_fm = [f for f in files if not meta[f]["fm"] or not meta[f]["fm"]["type"] or not meta[f]["fm"]["description"]]

    print("\n## Structure\n")
    print("Not in the index (never recalled): " + (", ".join(orphans) or "none"))
    print("Index links to a missing file: " + (", ".join(dead) or "none"))
    print("Missing frontmatter, type or description: " + (", ".join(no_fm) or "none"))

    dead_wiki = {}
    for name in files:
        for target in WIKI_LINK.findall(meta[name]["text"]):
            target = target.strip()
            if target not in names and target.replace("-", "_") not in names:
                dead_wiki.setdefault(target, []).append(name)
    print("`[[links]]` with no target: " + (", ".join(f"{t} (from {', '.join(s)})" for t, s in sorted(dead_wiki.items())) or "none"))

    big = sorted(((len(meta[f]["text"]), f) for f in files), reverse=True)[:8]
    print("\nLargest files: " + ", ".join(f"{f} ({size} c)" for size, f in big))

    print(f"\n## Project memories not changed in {args.stale_days}+ days\n")
    print("Project state goes stale fastest. Each one needs a verdict: still true, update, or delete.\n")
    old = sorted(((meta[f]["age"], f) for f in files if (meta[f]["fm"] or {}).get("type") == "project" and meta[f]["age"] >= args.stale_days), reverse=True)
    for age, name in old:
        print(f"- {name} ({age} d): {meta[name]['fm']['description'][:140]}")
    if not old:
        print("none")

    if ticket_re:
        keys = sorted(set(ticket_re.findall(index + "\n".join(m["text"] for m in meta.values()))))
        print(f"\n## Ticket keys ({len(keys)})\n")
        print("Check the status of these in the tracker with one query; a closed ticket under an active heading is stale.\n")
        print(", ".join(keys))

    claims = {}
    for source, text in [(args.index, index)] + [(f, meta[f]["text"]) for f in files]:
        for repo, number, own, snippet, head, src in pr_claims(source, text, aliases):
            claims.setdefault((repo, number), []).append((src, own, snippet, head))

    print(f"\n## Pull request claims ({len(claims)})\n")
    if not aliases:
        print("No repoAliases in the config, so no PR claims were resolved.")
        return
    if not args.live:
        print("Run with --live to compare these with GitHub.")
        return
    gh = find_gh()
    if not gh:
        print("gh not found; live check skipped.")
        return

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        states = dict(zip(claims, pool.map(lambda key: pr_state(gh, *key), claims)))

    stale, errors, agree = [], [], 0
    for (repo, number), mentions in sorted(claims.items()):
        state = states[(repo, number)]
        if "error" in state:
            errors.append(f"- {repo}#{number}: {state['error']} (from {mentions[0][0]})")
            continue
        live = state["state"]
        problems = []
        for src, own, snippet, head in mentions:
            if live in ("MERGED", "CLOSED") and not SETTLED.search(own):
                kind = "says it is still in progress" if PENDING.search(own) else "does not say it is settled"
                problems.append(f"  - {src}: memory {kind}: `{snippet}`")
            elif live == "OPEN" and head and not state["headRefOid"].startswith(head):
                problems.append(f"  - {src}: head is now {state['headRefOid'][:8]}, memory says {head}: `{snippet}`")
        if problems:
            when = (state.get("mergedAt") or state.get("closedAt") or "")[:10]
            stale.append(f"- {repo}#{number} is {live}{' ' + when if when else ''}\n" + "\n".join(problems))
        else:
            agree += 1

    wrong = [s for s in stale if "still in progress" in s or "head is now" in s]
    quiet = [s for s in stale if s not in wrong]
    print(f"{agree} agree with GitHub. {len(wrong)} contradict it. {len(quiet)} only mention a settled PR. {len(errors)} could not be read.\n")
    print("### Contradictions (memory says in progress, or names an old head)\n")
    print("\n".join(wrong) or "none")
    print("\n### Mentions of a settled PR (often history, not a claim)\n")
    print("\n".join(quiet) or "none")
    if errors:
        print("\n### Not readable (wrong alias match, or no access)\n")
        print("\n".join(errors))


if __name__ == "__main__":
    main()
