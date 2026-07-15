#!/usr/bin/env python3
"""Count what Claude Code actually repeated, across its session transcripts.

Claude Code logs every tool call it makes to ~/.claude/projects/<project>/<uuid>.jsonl.
Nobody reads those. This reads them and counts, so that "what should be a tool?"
is answered from evidence instead of a brainstorm.

Read-only. Stdlib only. Nothing leaves the machine.

    scripts/mine_transcripts.py                     # everything
    scripts/mine_transcripts.py --project shem      # one project
    scripts/mine_transcripts.py --top 40
    scripts/mine_transcripts.py --selftest

Printed examples are verbatim commands from your sessions -- eyeball before pasting
anywhere if the corpus covers confidential work.
"""

import argparse
import json
import pathlib
import shlex
import sys
from collections import Counter

# Commands whose second word is a verb, not an operand. `git log` is a shape;
# `grep foo` is not (foo is a pattern, and counting it would shatter the buckets).
# ponytail: explicit list, because guessing "bare word == subcommand" mis-shapes
# every grep/find/awk. Add entries as they show up in your own top-50.
MULTIVERB = {
    "git", "mix", "npm", "yarn", "pnpm", "cargo", "go", "docker", "podman",
    "kubectl", "oc", "systemctl", "journalctl", "dnf", "yum", "rpm", "apt",
    "pip", "pip3", "subscription-manager", "sos", "sosreport", "virsh", "ip",
    "gh", "brew", "shem",
}


def skeleton(cmd):
    """A command's shape, with the varying parts dropped.

    `git log --oneline -15` and `git log --oneline -3` are the same shape.
    Returns None for anything unparseable.
    """
    out = []
    for seg in _segments(cmd):
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        if not toks:
            continue
        prog = toks[0].rsplit("/", 1)[-1]
        rest = toks[1:]
        shape = [prog]
        if prog in MULTIVERB and rest and not rest[0].startswith("-"):
            shape.append(rest[0])
            rest = rest[1:]
        shape.extend(sorted(_flags(rest)))
        out.append(" ".join(shape))
    return " | ".join(out) or None


def _flags(tokens):
    """The flag names in a token list, with values and counts dropped.

    `-rn` -> {-r, -n} so it buckets with `-nr`. `--since=today` -> {--since}.
    `-15` is a count, not a flag -> dropped, so `git log -15` and `-3` agree.
    """
    found = set()
    for t in tokens:
        t = t.split("=", 1)[0]
        if not t.startswith("-") or t in ("-", "--"):
            continue
        if t.startswith("--"):
            found.add(t)
        elif t[1:].isdigit():
            continue
        else:
            found.update("-" + c for c in t[1:] if c.isalpha())
    return found


def _segments(cmd):
    """Split a command line on pipeline/sequence operators."""
    seg, depth, i = [], 0, 0
    buf = ""
    while i < len(cmd):
        c = cmd[i]
        if c in "'\"":
            j = cmd.find(c, i + 1)
            if j == -1:
                buf += cmd[i:]
                break
            buf += cmd[i : j + 1]
            i = j + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        if depth == 0:
            two = cmd[i : i + 2]
            if two in ("&&", "||"):
                seg.append(buf); buf = ""; i += 2; continue
            if c in "|;\n":
                seg.append(buf); buf = ""; i += 1; continue
        buf += c
        i += 1
    seg.append(buf)
    return [s.strip() for s in seg if s.strip()]


def tool_calls(path):
    """Yield (name, input) for every tool_use block in a transcript."""
    with open(path, errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            content = (rec.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    yield block.get("name", "?"), block.get("input") or {}


def mine(root, project=None):
    files = sorted(root.rglob("*.jsonl"))
    if project:
        files = [f for f in files if project in str(f.parent)]
    tools, shapes, examples = Counter(), Counter(), {}
    for path in files:
        for name, inp in tool_calls(path):
            tools[name] += 1
            if name == "Bash":
                cmd = inp.get("command")
                if not isinstance(cmd, str):
                    continue
                shape = skeleton(cmd)
                if shape:
                    shapes[shape] += 1
                    examples.setdefault(shape, cmd)
    return files, tools, shapes, examples


def report(files, tools, shapes, examples, top):
    total = sum(tools.values())
    print(f"{len(files)} transcripts, {total} tool calls\n")

    print("== tools used ==")
    for name, n in tools.most_common():
        print(f"{n:6d}  {name}")

    mcp = sum(n for name, n in tools.items() if name.startswith("mcp__"))
    print(f"\nMCP calls: {mcp} ({100 * mcp / total:.1f}% of all tool calls)"
          if total else "\nMCP calls: 0")

    print(f"\n== repeated bash shapes (top {top}) ==")
    print("anything here with a high count and a boring reason to exist is a tool candidate.\n")
    for shape, n in shapes.most_common(top):
        if n < 2:
            continue
        print(f"{n:6d}  {shape}")
        print(f"        e.g. {examples[shape][:110]}")


def selftest():
    cases = [
        ("git log --oneline -15", "git log --oneline"),
        ("git log --oneline -3", "git log --oneline"),
        ("grep -rn 'foo bar' /var/log", "grep -n -r"),
        ("grep -rn baz /etc", "grep -n -r"),
        ("/usr/bin/tar -xzf sos.tar.xz", "tar -f -x -z"),
        ("cat a.txt | grep -i err | wc -l", "cat | grep -i | wc -l"),
        ("mix test --only foo && echo ok", "mix test --only | echo"),
        ("journalctl -u sshd --since=today", "journalctl --since -u"),
        ("git log -15", "git log"),  # bare count is not a shape
        ("", None),
        ("   ", None),
    ]
    for cmd, want in cases:
        got = skeleton(cmd)
        assert got == want, f"{cmd!r}: got {got!r}, want {want!r}"
    # same shape, different operands -> same bucket. that is the whole point.
    assert skeleton("grep -rn a /x") == skeleton("grep -rn b /y")
    assert skeleton("unterminated 'quote") is not None  # must not raise
    print("selftest ok")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", type=pathlib.Path,
                   default=pathlib.Path.home() / ".claude" / "projects")
    p.add_argument("--project", help="only transcripts whose path contains this")
    p.add_argument("--top", type=int, default=25)
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()

    if a.selftest:
        selftest()
        return 0
    if not a.root.exists():
        print(f"no transcripts at {a.root}", file=sys.stderr)
        return 1
    files, tools, shapes, examples = mine(a.root, a.project)
    if not files:
        print("no transcripts matched", file=sys.stderr)
        return 1
    report(files, tools, shapes, examples, a.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
