#!/usr/bin/env python3
"""Before/after token bench for the token-saving pitch.

Q: to answer a *structural* codebase question ("where is X, what connects to it"),
how many context tokens via graphify_query (find->neighbors) vs reading the files
an agent would otherwise open?

graphify side = exact payload the seed tool returns (same find->neighbors math).
naive side    = bytes of the file(s) an agent reads to learn the same structure.
token est     = chars/4.  # ponytail: chars/4 ratio, swap in a real tokenizer if a
                          # publishable absolute number (not a ratio) is needed.
"""
import json, os, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (bench/ -> ..)
G = json.load(open(f"{ROOT}/graphify-out/graph.json"))
NODES, LINKS = G["nodes"], G["links"]
LABEL = {n["id"]: n.get("label", "") for n in NODES}

def toks(s): return len(s) // 4

def find(q):
    ql = q.lower()
    return [n["id"] for n in NODES if ql in (n.get("label") or "").lower()]

def neighbors(i):
    out = []
    for l in LINKS:
        if l["source"] == i: out.append((l["target"], l.get("relation")))
        elif l["target"] == i: out.append((l["source"], l.get("relation")))
    return [{"id": o, "label": LABEL.get(o), "relation": r} for o, r in out]

def graphify_payload(q):
    ids = find(q)
    return {"find": ids, "neighbors": {i: neighbors(i) for i in ids}}

def files_for(grep_term):
    """files an agent would open: definition + callers (grep -l, src only)."""
    r = subprocess.run(["grep", "-rIl", grep_term, f"{ROOT}/lib", f"{ROOT}/test"],
                       capture_output=True, text=True)
    return [f for f in r.stdout.splitlines() if f]

# Three real structural questions about this codebase.
QUESTIONS = [
    ("GraduationGate", "Where is the graduation gate and what touches it?"),
    ("Agent.Server",   "Where is the agent server and what connects to it?"),
    ("EventLog",       "Where is the EventLog and what depends on it?"),
]

print(f"graph: {len(NODES)} nodes / {len(LINKS)} edges\n")
tot_g = tot_n = 0
for term, desc in QUESTIONS:
    g = json.dumps(graphify_payload(term))
    gt = toks(g)
    files = files_for(term)
    nbytes = sum(os.path.getsize(f) for f in files)
    nt = nbytes // 4
    tot_g += gt; tot_n += nt
    ratio = nt / gt if gt else 0
    print(f"Q: {desc}")
    print(f"   graphify find->neighbors : {gt:>7,} tok  ({len(find(term))} hits)")
    print(f"   read {len(files):>2} matching files     : {nt:>7,} tok  ({nbytes:,} bytes)")
    print(f"   savings                  : {1-gt/nt:6.1%}  ({ratio:.0f}x less)\n")

print(f"TOTAL  graphify {tot_g:,} tok   vs   read-files {tot_n:,} tok   "
      f"=> {1-tot_g/tot_n:.1%} fewer ({tot_n/tot_g:.0f}x)")

# self-check: the bench is meaningless if graphify isn't actually smaller.
assert tot_g < tot_n, "graphify path should cost fewer tokens than reading files"
assert find("GraduationGate"), "find() returned nothing — graph/label mismatch"
print("\nok")
