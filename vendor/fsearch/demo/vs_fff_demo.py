"""fsearch and fff side by side on one folder, then the numbers from vs_fff.py.

Typed into by vs_fff.tape (vhs): each keystroke runs both engines. A query
starting with `grep:` searches file contents when Enter is pressed. Esc
shows the numbers card.
usage: python3 vs_fff_demo.py <folder> <vs_fff.json> <folder label>
"""

import json, os, shutil, socket, statistics, sys, termios, time, tty
import fff

ROOT = os.path.realpath(sys.argv[1])
RES = json.load(open(sys.argv[2]))
LABEL = sys.argv[3]
W = min(shutil.get_terminal_size().columns, 116)
COL = (W - 7) // 2

RESET, BOLD, DIM = "\x1b[0m", "\x1b[1m", "\x1b[2m"
def rgb(r, g, b): return f"\x1b[38;2;{r};{g};{b}m"
GREEN, BLUE, RED, GREY, WHITE = rgb(120, 220, 140), rgb(120, 170, 255), rgb(255, 120, 110), rgb(110, 110, 120), rgb(235, 235, 240)

sock = socket.socket(socket.AF_UNIX)
sock.connect(os.path.expanduser("~/Library/Application Support/FSearch/fsearch.sock"))
conn = sock.makefile("rw")
finder = fff.FileFinder(ROOT, frecency_db_path="/tmp/vs_fff_frecency", history_db_path="/tmp/vs_fff_history")
finder.wait_for_scan_blocking(timeout_ms=600_000)
while not finder.scan_progress.is_warmup_complete:
    time.sleep(0.05)

def timed(f):
    t = time.perf_counter()
    r = f()
    return r, (time.perf_counter() - t) * 1000

def fsearch(q):
    if q.startswith("grep:"):
        req = {"op": "grep", "q": f"in:{ROOT}", "pattern": q[5:], "mode": "literal", "limit": 50, "per_file": 1, "budget_ms": 0}
    else:
        req = {"q": f"in:{ROOT} {q}", "limit": 50}
    def ask():
        conn.write(json.dumps(req) + "\n")
        conn.flush()
        return json.loads(conn.readline())
    r, ms = timed(ask)
    rows = [(f["path"], f["matches"][0]["line"]) for f in r.get("files", [])] or [(h["path"], None) for h in r.get("hits", [])]
    return [(os.path.relpath(p, ROOT), n) for p, n in rows], ms

def ff(q):
    if q.startswith("grep:"):
        r, ms = timed(lambda: finder.grep(q[5:], page_limit=50, max_matches_per_file=1))
        return [(i.relative_path, i.line_number) for i in r.items], ms
    r, ms = timed(lambda: finder.search(q, page_size=50))
    return [(i.relative_path, None) for i in r.items], ms

def ms(x): return f"{x:.1f} ms" if x < 10 else f"{x:.0f} ms"
def out(s): sys.stdout.write(s); sys.stdout.flush()

def cell(path, line):
    d, _, name = path.rpartition("/")
    name += f":{line}" if line else ""
    d = d[: max(0, COL - len(name) - 2)]
    return f"{WHITE}{name}{RESET}  {GREY}{d}{RESET}", len(name) + 2 + len(d)

def spark(ts):
    bars = "▁▂▃▄▅▆▇█"
    top = max(max(ts[-20:]), 1)
    return "".join(bars[min(7, int(t / top * 7))] for t in ts[-20:])

times = {"fsearch": [], "fff": []}

def draw(q, a, b):
    lines = ["", f"  {BOLD}{WHITE}fsearch vs fff{RESET}  {GREY}{LABEL} · {RES['folder_files']:,} files · same Mac, same queries{RESET}", ""]
    lines += [f"  {BLUE}❯{RESET} {BOLD}{WHITE}{q}{RESET}{BLUE}▌{RESET}", ""]
    head = []
    for name, color, r in (("fsearch", GREEN, a), ("fff", RED, b)):
        badge = ms(r[1]) if q else ""
        head.append((f"{BOLD}{WHITE}{name}{RESET}" + " " * (COL - len(name) - len(badge)) + f"{BOLD}{color}{badge}{RESET}", COL))
    sep = f" {GREY}│{RESET} "
    lines.append("  " + head[0][0] + sep + head[1][0])
    lines.append(f"  {GREY}{'─' * COL}{RESET}{sep}{GREY}{'─' * COL}{RESET}")
    for k in range(9):
        cells = []
        for r in (a, b):
            c, n = cell(*r[0][k]) if k < len(r[0]) else ("", 0)
            cells.append(c + " " * (COL - n))
        lines.append("  " + cells[0] + sep + cells[1])
    lines.append("")
    if times["fff"]:
        foot = []
        for name, color in (("fsearch", GREEN), ("fff", RED)):
            med = f"median {ms(statistics.median(times[name]))}"
            sp = spark(times[name])
            foot.append(f"{color}{sp}{RESET}" + " " * (COL - len(sp) - len(med)) + f"{GREY}median {RESET}{color}{med[7:]}{RESET}")
        lines.append("  " + foot[0] + sep + foot[1])
    out("\x1b[H\x1b[2J" + "\r\n".join(lines))

def race():
    q, a, b = "", ([], 0.0), ([], 0.0)
    draw(q, a, b)
    while True:
        c = sys.stdin.read(1)
        if c == "\x1b":
            return
        if c == "\x15":
            q = ""
        elif c == "\x7f":
            q = q[:-1]
        elif c.isprintable():
            q += c
        elif c not in "\r\n":
            continue
        grep = q.startswith("grep:") or "grep:".startswith(q)
        if q and (not grep or c in "\r\n"):
            a, b = fsearch(q), ff(q)
            times["fsearch"].append(a[1])
            times["fff"].append(b[1])
        else:
            a, b = ([], 0.0), ([], 0.0)
        draw(q, a, b)

def bars(title, unit, ours, theirs, note=""):
    lo, hi = min(ours, theirs), max(ours, theirs)
    win = f"{hi / lo:,.0f}× {'faster' if unit != 'MB' else 'less'}" if ours < theirs else ""
    out(f"  {BOLD}{WHITE}{title}{RESET}  {GREEN}{BOLD}{win}{RESET}  {GREY}{note}{RESET}\r\n")
    width = W - 30
    for label, v, color in (("fsearch", ours, GREEN), ("fff", theirs, RED)):
        n = max(1, round(width * v / hi))
        for i in range(1, n + 1, max(1, n // 25)):
            out(f"\r    {WHITE}{label:<9}{RESET}{color}{'█' * i}{RESET}")
            time.sleep(0.015)
        u, x = ("ms", v * 1000) if unit == "s" and v < 1 else (unit, v)
        val = f"{x:.1f} ms" if u == "ms" and x < 10 else f"{x:.0f} ms" if u == "ms" else f"{x:.1f} s" if u == "s" else f"{x:,.0f} MB"
        out(f"\r    {WHITE}{label:<9}{RESET}{color}{'█' * n}{RESET} {BOLD}{color}{val}{RESET}\r\n")
    out("\r\n")
    time.sleep(0.5)

def card():
    f, x = RES["fsearch"], RES["fff"]
    out("\x1b[H\x1b[2J\r\n")
    bars("Find a file by name", "ms", f["name_ms"]["p50"], x["name_ms"]["p50"], f"median of {RES['queries']:,} queries")
    bars("Search inside files", "ms", f["grep_ms"]["p50"], x["grep_ms"]["p50"], f"median of {RES['patterns']} patterns")
    bars("Ready after launch", "s", f["ready_s"], x["ready_s"], "first search answered")
    bars("Memory", "MB", f["memory_mb"], x["memory_mb"], f"fsearch: whole disk, {f['entries'] / 1e6:.1f}M files · fff: this folder")
    out(f"  {BOLD}{WHITE}Typo in the name, right file first{RESET}   {GREEN}{BOLD}fsearch {f['typo_top1']:.0%}{RESET}   {RED}{BOLD}fff {x['typo_top1']:.0%}{RESET}\r\n")
    sys.stdin.read(1)

fd_ = sys.stdin.fileno()
saved = termios.tcgetattr(fd_)
tty.setcbreak(fd_)
out("\x1b[?25l")
try:
    race()
    card()
finally:
    termios.tcsetattr(fd_, termios.TCSADRAIN, saved)
    out("\x1b[?25h")
