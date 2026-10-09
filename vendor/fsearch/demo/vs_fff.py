"""fsearch vs fff on one folder, each through its own interface: fff in-process
(its Python package), fsearch through its daemon's socket (what the CLI uses).

usage: python3 vs_fff.py <folder> [out.json]
needs: pip install fff-search, and the fsearch daemon up with <folder> indexed.
Restarts the fsearch daemon once to time its start.
"""

import json, os, random, re, socket, statistics, subprocess, sys, time
import fff

ROOT = os.path.realpath(sys.argv[1])
OUT = sys.argv[2] if len(sys.argv) > 2 else "vs_fff.json"
SOCK = os.path.expanduser("~/Library/Application Support/FSearch/fsearch.sock")
FSEARCH = os.path.expanduser("~/.local/bin/fsearch")
rng = random.Random(1)


def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", out)
    return float(m[1]) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m[2]]


def daemon_pid():
    out = subprocess.run(["pgrep", "-x", "fsearch"], capture_output=True, text=True).stdout.split()
    return int(out[0])


def stats(ms):
    ms = sorted(ms)
    return {"p50": statistics.median(ms), "p90": ms[int(len(ms) * 0.9)], "n": len(ms)}


# Targets: files both engines index (fd's view: not hidden, not gitignored,
# like fff's), with a name that is unique among them.
files = {}
for p in subprocess.run(["fd", "-t", "f", "-0", ".", ROOT], capture_output=True, check=True).stdout.decode().split("\0")[:-1]:
    files.setdefault(os.path.basename(p), []).append(p)
pool = sorted(n for n, p in files.items() if len(p) == 1 and 6 <= len(n) <= 32 and n.isascii() and " " not in n
              and sum(c.isalpha() for c in n) >= 5)
targets = rng.sample(pool, 300)


def typo(name, kind):
    """One typo on a letter, never the first char (fsearch needs that one)."""
    s = list(name)
    letters = [i for i in range(1, len(s)) if s[i].isalpha()]
    p = rng.choice(letters)
    if kind == "swap":
        pairs = [i for i in letters if i + 1 < len(s) and s[i + 1].isalpha() and s[i] != s[i + 1]]
        if not pairs:
            return None
        p = rng.choice(pairs)
        s[p], s[p + 1] = s[p + 1], s[p]
    elif kind == "drop":
        del s[p]
    elif kind == "extra":
        s.insert(p, rng.choice("abcdefghijklmnopqrstuvwxyz"))
    else:
        s[p] = rng.choice([c for c in "abcdefghijklmnopqrstuvwxyz" if c != s[p].lower()])
    return "".join(s)


queries = [(t, t) for t in targets]
queries += [(q, t) for t in targets for k in ("swap", "drop", "extra", "subst") if (q := typo(t, k))]

# Content patterns: identifiers from random source files (mostly rare), plus common ones.
srcs = [p for ps in files.values() for p in ps if p.endswith((".c", ".h", ".rs", ".ts", ".tsx", ".js", ".py", ".go", ".swift"))]
idents = set()
while len(idents) < 60:
    words = re.findall(r"\b[a-z][a-z0-9_]{9,30}\b", open(rng.choice(srcs), errors="ignore").read())
    if words:
        idents.add(rng.choice(words))
patterns = sorted(idents) + ["mutex_lock", "kmalloc", "EXPORT_SYMBOL_GPL", "spin_lock_irqsave", "struct device", "TODO", "return -EINVAL"]

# fsearch: start from a stopped daemon; time the CLI's first answer.
os.kill(daemon_pid(), 15)
while os.path.exists(SOCK) and subprocess.run(["pgrep", "-x", "fsearch"], capture_output=True).returncode == 0:
    time.sleep(0.05)
t = time.perf_counter()
subprocess.run([FSEARCH, f"in:{ROOT}", "Makefile"], capture_output=True, check=True)
fs_ready = time.perf_counter() - t
sock = socket.socket(socket.AF_UNIX)
sock.connect(SOCK)
conn = sock.makefile("rw")


def fs(req):
    t = time.perf_counter()
    conn.write(json.dumps(req) + "\n")
    conn.flush()
    r = json.loads(conn.readline())
    assert r.get("ok"), r
    return (time.perf_counter() - t) * 1000, r


while fs({"op": "status"})[1]["content_pending"]:
    time.sleep(0.5)

# fff: time to a searchable index, then to its warmed content cache.
base_mb = footprint_mb(os.getpid())
t = time.perf_counter()
finder = fff.FileFinder(ROOT, frecency_db_path="/tmp/vs_fff_frecency", history_db_path="/tmp/vs_fff_history")
finder.wait_for_scan_blocking(timeout_ms=600_000)
fff_ready = time.perf_counter() - t
while not finder.scan_progress.is_warmup_complete:
    time.sleep(0.05)
fff_warm = time.perf_counter() - t
fff_files = finder.scan_progress.scanned_files_count


def ff_search(q):
    t = time.perf_counter()
    r = finder.search(q, page_size=50)
    return (time.perf_counter() - t) * 1000, [os.path.join(ROOT, i.relative_path) for i in r.items]


def fs_search(q):
    ms, r = fs({"q": f"in:{ROOT} {q}", "limit": 50})
    return ms, [h["path"] for h in r["hits"]]


def ff_grep(p, limit=50):
    t = time.perf_counter()
    r = finder.grep(p, page_limit=limit, max_matches_per_file=1)
    return (time.perf_counter() - t) * 1000, {os.path.join(ROOT, i.relative_path) for i in r.items}


def fs_grep(p, limit=50):
    ms, r = fs({"q": f"in:{ROOT}", "pattern": p, "op": "grep", "mode": "literal", "limit": limit, "per_file": 1, "budget_ms": 0})
    return ms, {f["path"] for f in r["files"]}


res = {"folder_files": fff_files, "fsearch": {}, "fff": {}}
for name, search, grep in (("fsearch", fs_search, fs_grep), ("fff", ff_search, ff_grep)):
    search("warmup")
    grep("warmup")

# Name search: every query, the engines take turns going first.
times = {"fsearch": [], "fff": []}
found = {"fsearch": {"exact": [0, 0], "typo": [0, 0]}, "fff": {"exact": [0, 0], "typo": [0, 0]}}
for i, (q, target) in enumerate(queries):
    order = [("fsearch", fs_search), ("fff", ff_search)][:: 1 if i % 2 else -1]
    for name, search in order:
        ms, hits = search(q)
        times[name].append(ms)
        f = found[name]["exact" if q == target else "typo"]
        f[0] += bool(hits) and os.path.basename(hits[0]) == target
        f[1] += 1
for name in times:
    res[name]["name_ms"] = stats(times[name])
    res[name]["exact_top1"] = found[name]["exact"][0] / found[name]["exact"][1]
    res[name]["typo_top1"] = found[name]["typo"][0] / found[name]["typo"][1]

# Content search: first 50 files with a match, then every file (to compare what each finds).
times = {"fsearch": [], "fff": []}
agree = []
for i, p in enumerate(patterns):
    for name, grep in [("fsearch", fs_grep), ("fff", ff_grep)][:: 1 if i % 2 else -1]:
        times[name].append(grep(p)[0])
    a, b = fs_grep(p, 100_000)[1], ff_grep(p, 100_000)[1]
    agree.append((len(a & b), len(a), len(b)))
for name in times:
    res[name]["grep_ms"] = stats(times[name])
res["grep_files"] = {"both": sum(x[0] for x in agree), "fsearch": sum(x[1] for x in agree), "fff": sum(x[2] for x in agree)}

res["fsearch"]["ready_s"] = fs_ready
res["fff"]["ready_s"] = fff_ready
res["fff"]["warm_s"] = fff_warm
res["fsearch"]["memory_mb"] = footprint_mb(daemon_pid())
res["fff"]["memory_mb"] = footprint_mb(os.getpid()) - base_mb
res["fsearch"]["entries"] = fs({"op": "status"})[1]["entries"]
res["patterns"], res["queries"] = len(patterns), len(queries)
json.dump(res, open(OUT, "w"), indent=1)
print(json.dumps(res, indent=1))
