"""Measure the runtime's typed queues (spec 11.2) as they are today.

python bench/queues.py --exe build/goose --reps 5 --wait-idle 300

Builds bench/goose/queues.goose with `goose build --cc clang -O2` and runs
each configuration in a fresh process, --reps times, in this order:

* rt1:   qput then qget of one message on one thread (a round trip with no
         wait), 16 bytes and 32 KB;
* burst: n qputs, then n qgets, on one thread;
* empty: n qpolls of an empty queue, on one thread (what asking costs when
         nothing is there);
* rt2:   a message to a worker waiting in qget and its answer back: two
         wake-ups per round trip;
* drain: n messages queued before 1, 2, 4, 8 or 16 consumers start, which
         then take them all (a pool of workers draining a work queue);
* tput:  1, 2, 4, 8 or 16 producers putting n messages in all while 1, 2,
         4, 8 or 16 consumers take them, every pair of counts.

With --floor it also builds bench/queues_floor.c (Linux) and measures what
the machine allows a queue without one: a contended atomic, a spinning
handoff and a futex wake-up between two threads, malloc and free on one
thread and across two, and a copy of 32 KB.

Every sample is kept in the JSON (--json); the tables (--markdown) show
medians. The baseline these numbers set is the one docs/design/
inboxes_select.md asks the queue work to beat; bench/queues.md has the
committed session.
"""
import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import toolchain as tc  # noqa: E402

COUNTS = [1, 2, 4, 8, 16]
SIZES = [16, 32768]
# Messages per run: enough for a run of tens of milliseconds at least.
N = {
    "rt1": {16: 2000000, 32768: 20000},
    "burst": {16: 1000000, 32768: 20000},
    "empty": {16: 2000000, 32768: 2000000},
    "rt2": {16: 20000, 32768: 5000},
    "drain": {16: 400000, 32768: 20000},
    "tput": {16: 400000, 32768: 20000},
}
QUICK = {"rt1": 20000, "burst": 20000, "empty": 20000, "rt2": 500, "drain": 20000, "tput": 20000}
QUICK_LARGE = {"rt1": 500, "burst": 500, "empty": 20000, "rt2": 100, "drain": 1000, "tput": 1000}


def configurations(quick, counts):
    def n(mode, size):
        if quick:
            return (QUICK if size == 16 else QUICK_LARGE)[mode]
        return N[mode][size]

    for size in SIZES:
        yield dict(mode="rt1", size=size, n=n("rt1", size))
    for size in SIZES:
        yield dict(mode="burst", size=size, n=n("burst", size))
    yield dict(mode="empty", size=16, n=n("empty", 16))
    for size in SIZES:
        yield dict(mode="rt2", size=size, n=n("rt2", size))
    for size in SIZES:
        for c in counts:
            yield dict(mode="drain", size=size, consumers=c, n=n("drain", size))
    for size in SIZES:
        for p in counts:
            for c in counts:
                yield dict(mode="tput", size=size, producers=p, consumers=c, n=n("tput", size))


def argv_of(binary, cfg):
    mode = cfg["mode"]
    if mode in ("rt1", "rt2", "burst", "empty"):
        rest = [cfg["n"], cfg["size"]]
    elif mode == "drain":
        rest = [cfg["consumers"], cfg["n"], cfg["size"]]
    else:
        rest = [cfg["producers"], cfg["consumers"], cfg["n"], cfg["size"]]
    return [str(binary), mode, *map(str, rest)]


def parse(line):
    out = {}
    for field in line.split():
        k, _, v = field.partition("=")
        out[k] = int(v) if v.lstrip("-").isdigit() else v
    return out


# The figure each mode is summarized by, its median taken over the samples.
PRIMARY = {
    "rt1": ["ns_per_round_trip"],
    "burst": ["ns_per_put", "ns_per_get"],
    "empty": ["ns_per_poll"],
    "rt2": ["ns_p50", "ns_p99", "ns_mean", "ns_min"],
    "drain": ["ns_per_msg", "msgs_per_s", "mb_per_s"],
    "tput": ["ns_per_msg", "msgs_per_s", "mb_per_s"],
}


def load1():
    try:
        return os.getloadavg()[0]
    except (AttributeError, OSError):
        return None


def machine_busy():
    """CPU-seconds every CPU has spent busy since boot (Linux), else None."""
    try:
        with open("/proc/stat") as f:
            vals = [int(v) for v in f.readline().split()[1:9]]
    except (OSError, ValueError):
        return None
    return (sum(vals) - vals[3] - vals[4]) / os.sysconf("SC_CLK_TCK")


def children_cpu():
    try:
        import resource
    except ImportError:
        return None
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime


def cpu_model():
    """The CPU's model name; lscpu has it where /proc/cpuinfo does not (arm64)."""
    try:
        p = subprocess.run(["lscpu"], capture_output=True, text=True, timeout=10)
        for line in p.stdout.splitlines():
            if line.startswith("Model name:"):
                return line.split(":", 1)[1].strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return tc.cpu_name()


def wait_idle(limit_s, below=2.0):
    """Waits for the 1-minute load average to drop below `below`."""
    if limit_s <= 0 or load1() is None:
        return load1()
    deadline = time.time() + limit_s
    while load1() >= below and time.time() < deadline:
        time.sleep(5)
    return load1()


def build(exe, cc, out):
    out.mkdir(parents=True, exist_ok=True)
    binary = out / ("queues" + tc.EXE_SUFFIX)
    src = ROOT / "bench" / "goose" / "queues.goose"
    p = subprocess.run([str(exe), "build", "--cc", cc, "-O2", "-o", str(binary), str(src)],
                       capture_output=True, text=True, timeout=600)
    if p.returncode:
        sys.exit(f"building {src} failed:\n{p.stdout}{p.stderr}")
    return binary


def run_reps(binary, cfg, reps):
    """Runs a configuration reps times; its samples, and the CPUs that other
    processes kept busy meanwhile (None where that cannot be read)."""
    busy0, mine0, t0 = machine_busy(), children_cpu(), time.perf_counter()
    samples = [run_one(binary, cfg, timeout=600) for _ in range(reps)]
    busy1, mine1, t1 = machine_busy(), children_cpu(), time.perf_counter()
    if None in (busy0, busy1, mine0, mine1):
        return samples, None
    return samples, max(0.0, (busy1 - busy0) - (mine1 - mine0)) / max(t1 - t0, 1e-9)


def run_one(binary, cfg, timeout):
    p = subprocess.run(argv_of(binary, cfg), capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f"{' '.join(argv_of(binary, cfg))} failed ({p.returncode}):\n"
                           f"{p.stdout}{p.stderr}")
    lines = [ln for ln in p.stdout.splitlines() if ln.startswith("mode=")]
    if len(lines) != 1:
        raise RuntimeError(f"unexpected output:\n{p.stdout}{p.stderr}")
    return parse(lines[0])


def build_floor(cc, out):
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "queues_floor"
    src = ROOT / "bench" / "queues_floor.c"
    p = subprocess.run([cc, "-O2", "-pthread", str(src), "-o", str(binary)], capture_output=True,
                       text=True, timeout=300)
    if p.returncode:
        sys.exit(f"building {src} failed:\n{p.stdout}{p.stderr}")
    return binary


FLOOR_KEYS = ("ns_per_op", "ns_per_round_trip", "ns_per_block", "ns_per_copy")


def run_floor(binary, reps, quick):
    """The floor's figures by what they measure: their samples and median."""
    runs = []
    for _ in range(reps):
        p = subprocess.run([str(binary)] + (["--quick"] if quick else []), capture_output=True,
                           text=True, timeout=1200)
        if p.returncode:
            raise RuntimeError(f"{binary} failed ({p.returncode}):\n{p.stdout}{p.stderr}")
        runs.append([parse(ln) for ln in p.stdout.splitlines() if ln.startswith("mode=")])
    out = []
    for i, first in enumerate(runs[0]):
        key = next(k for k in FLOOR_KEYS if k in first)
        what = {k: v for k, v in first.items() if k not in FLOOR_KEYS}
        values = [float(r[i][key]) for r in runs]
        out.append(dict(what=what, key=key, samples=values, median=statistics.median(values)))
    return out


def render_floor(floor):
    def get(**kw):
        for f in floor:
            if all(str(f["what"].get(k)) == str(v) for k, v in kw.items()):
                return f["median"]
        return None

    def ns(v):
        return "" if v is None else f"{v:,.0f} ns" if v >= 100 else f"{v:.1f} ns"

    out = []
    W = out.append
    W("**What the machine allows** (`bench/queues_floor.c`, no queue): the costs a queue is "
      "made of, medians.")
    W("")
    W("| one shared counter, threads | " + " | ".join(str(c) for c in COUNTS) + " |")
    W("|---|" + "---:|" * len(COUNTS))
    for op, name in (("faa", "`fetch_add`, ns per increment"), ("cas", "compare-exchange loop")):
        W(f"| {name} | " + " | ".join(ns(get(mode="atomic", threads=c, op=op)) for c in COUNTS) + " |")
    W("")
    W("| between two threads, or on one | |")
    W("|---|---:|")
    W(f"| a turn passed back and forth by spinning on a shared word, round trip | "
      f"{ns(get(mode='handoff'))} |")
    W(f"| the same, each side sleeping in `futex_wait` until woken, round trip | {ns(get(mode='futex'))} |")
    W(f"| `malloc` + `free` of 16 B on one thread | {ns(get(mode='malloc', size=16, where='local'))} |")
    W(f"| `malloc` of 16 B on one thread, `free` on another | {ns(get(mode='malloc', size=16, where='remote'))} |")
    W(f"| `malloc` + `free` of 32 KB on one thread | {ns(get(mode='malloc', size=32768, where='local'))} |")
    W(f"| `malloc` of 32 KB on one thread, `free` on another | "
      f"{ns(get(mode='malloc', size=32768, where='remote'))} |")
    W(f"| `memcpy` of 32 KB in cache | {ns(get(mode='memcpy', **{'from': 'cache'}))} |")
    W(f"| `memcpy` of 32 KB streamed from memory | {ns(get(mode='memcpy', **{'from': 'memory'}))} |")
    return "\n".join(out)


def label(cfg):
    parts = [cfg["mode"], f"{cfg['size']}B"]
    if "producers" in cfg:
        parts.append(f"p{cfg['producers']}")
    if "consumers" in cfg:
        parts.append(f"c{cfg['consumers']}")
    return " ".join(parts)


def medians(samples, keys):
    return {k: statistics.median(s[k] for s in samples) for k in keys}


def git_head():
    p = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True,
                       text=True)
    return p.stdout.strip() or None


def goose_version(exe):
    p = subprocess.run([str(exe), "version"], capture_output=True, text=True)
    return (p.stdout or p.stderr).strip()


# --- tables -----------------------------------------------------------------------

def find(results, **kw):
    for r in results:
        if all(r["config"].get(k) == v for k, v in kw.items()):
            return r
    return None


def us(ns):
    return f"{ns / 1000:.1f}"


def render(data):
    res = data["results"]
    meta = data["meta"]
    out = []
    W = out.append
    if not res and data.get("floor"):
        return render_floor(data["floor"])
    bgs = [r["background_cpus"] for r in res if r.get("background_cpus") is not None]
    bg = (f" Other processes kept at most {max(bgs):.2f} CPUs busy while a configuration ran "
          f"(median {statistics.median(bgs):.2f}).") if bgs else ""
    W(f"Measured {meta['date']} at commit `{meta['commit']}` ({meta['goose']}), "
      f"`{meta['cc']} -O2`, on {meta['cpu']} ({meta['cpus']} CPUs), {meta['os']}. "
      f"Medians of {meta['reps']} runs, each a process of its own; 1-minute load average "
      f"{meta['load_before']} before and {meta['load_after']} after.{bg}")
    W("")

    def has(mode):
        return any(r["config"]["mode"] == mode for r in res)

    def cell(r, key, fmt):
        return fmt(r["median"][key]) if r else ""

    if has("rt1") or has("burst") or has("rt2") or has("empty"):
        W("**One message at a time.** `rt1` is `qput` then `qget` on one thread; `burst` is n "
          "`qput`s and then n `qget`s on one thread; `rt2` is a message to a worker waiting in "
          "`qget<T>()` and its answer back, two wake-ups.")
        W("")
        W("| message | rt1 round trip | burst: qput | burst: qget | rt2 round trip, p50 | rt2 p99 | rt2 min |")
        W("|---|---:|---:|---:|---:|---:|---:|")
        for size in SIZES:
            a = find(res, mode="rt1", size=size)
            b = find(res, mode="burst", size=size)
            c = find(res, mode="rt2", size=size)
            ns = lambda v: f"{v:,.0f} ns"  # noqa: E731
            micro = lambda v: f"{us(v)} us"  # noqa: E731
            W(f"| {'16 B' if size == 16 else '32 KB'} | {cell(a, 'ns_per_round_trip', ns)} "
              f"| {cell(b, 'ns_per_put', ns)} | {cell(b, 'ns_per_get', ns)} "
              f"| {cell(c, 'ns_p50', micro)} | {cell(c, 'ns_p99', micro)} "
              f"| {cell(c, 'ns_min', micro)} |")
        W("")
        e = find(res, mode="empty")
        if e:
            W(f"A `qpoll` of an empty queue (`empty`) costs {e['median']['ns_per_poll']:,.0f} ns.")
            W("")
    if has("drain"):
        W(drain_table(res))
    if has("tput"):
        W(tput_tables(res))
    if data.get("floor"):
        W(render_floor(data["floor"]))
    return "\n".join(out)


def drain_table(res):
    out = []
    W = out.append
    W("**Draining a full queue** (`drain`): n messages queued before the consumers start, "
      "then taken by all of them, as a pool of workers takes the jobs main queued. "
      "Wall time per message, and the total rate.")
    W("")
    W("| consumers | " + " | ".join(f"{c}" for c in COUNTS) + " |")
    W("|---|" + "---:|" * len(COUNTS))
    for size in SIZES:
        cells, rates = [], []
        for c in COUNTS:
            r = find(res, mode="drain", size=size, consumers=c)
            cells.append(f"{r['median']['ns_per_msg']:,.0f} ns" if r else "")
            if r and size == 16:
                rates.append(f"{r['median']['msgs_per_s'] / 1e6:.1f} M/s")
            elif r:
                rates.append(f"{r['median']['mb_per_s'] / 1000:.1f} GB/s")
            else:
                rates.append("")
        name = "16 B" if size == 16 else "32 KB"
        W(f"| {name}, per message | " + " | ".join(cells) + " |")
        W(f"| {name}, total | " + " | ".join(rates) + " |")
    W("")
    return "\n".join(out)


def tput_tables(res):
    out = []
    W = out.append
    for size in SIZES:
        if size == 16:
            W("**Throughput, 16-byte messages** (`tput`): millions of messages a second "
              "through one queue, producers (rows) putting while consumers (columns) take; "
              "in brackets, the wall time per message.")
        else:
            W("**Throughput, 32 KB messages** (`tput`): GB/s through one queue, producers "
              "(rows) putting while consumers (columns) take; in brackets, the wall time per "
              "message.")
        W("")
        W("| producers \\ consumers | " + " | ".join(str(c) for c in COUNTS) + " |")
        W("|---|" + "---:|" * len(COUNTS))
        for p in COUNTS:
            cells = []
            for c in COUNTS:
                r = find(res, mode="tput", size=size, producers=p, consumers=c)
                if not r:
                    cells.append("")
                    continue
                m = r["median"]
                if size == 16:
                    cells.append(f"{m['msgs_per_s'] / 1e6:.2f} ({m['ns_per_msg']:,.0f} ns)")
                else:
                    cells.append(f"{m['mb_per_s'] / 1000:.2f} ({us(m['ns_per_msg'])} us)")
            W(f"| {p} | " + " | ".join(cells) + " |")
        W("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", help="the goose compiler (default: the one under build/)")
    ap.add_argument("--cc", default="clang", help="the C compiler goose build uses (default clang)")
    ap.add_argument("--reps", type=int, default=5, help="runs per configuration (default 5)")
    ap.add_argument("--quick", action="store_true", help="few messages and one run: a smoke test")
    ap.add_argument("--counts", type=int, nargs="+", default=COUNTS,
                    help="producer and consumer counts (default 1 2 4 8 16)")
    ap.add_argument("--only", nargs="+", choices=sorted(N), help="run only these modes")
    ap.add_argument("--floor", action="store_true",
                    help="also measure bench/queues_floor.c, what the machine allows (Linux)")
    ap.add_argument("--floor-only", action="store_true", help="measure only the floor")
    ap.add_argument("--wait-idle", type=float, default=0, metavar="SECONDS",
                    help="wait up to this long for the 1-minute load average to drop below 2")
    ap.add_argument("--max-background", type=float, default=0.5, metavar="CPUS",
                    help="run a configuration again (after --wait-idle) when other processes "
                         "kept more CPUs than this busy while it ran (default 0.5)")
    ap.add_argument("--tries", type=int, default=4,
                    help="the most times a disturbed configuration is run (default 4)")
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "bench" / "queues",
                    help="where the program is built")
    ap.add_argument("--json", type=Path, help="write every sample here")
    ap.add_argument("--markdown", type=Path, help="write the tables here")
    ap.add_argument("--render", type=Path, metavar="JSON",
                    help="only print the tables of an earlier --json")
    args = ap.parse_args()

    if args.render:
        print(render(json.loads(args.render.read_text(encoding="utf-8"))))
        return

    exe = tc.find_goose(args.exe)
    reps = 1 if args.quick else args.reps
    binary = build(exe, args.cc, args.out)
    cfgs = [c for c in configurations(args.quick, args.counts)
            if (not args.only or c["mode"] in args.only) and not args.floor_only]
    before = wait_idle(args.wait_idle)
    results = []
    for cfg in cfgs:
        for attempt in range(1, max(args.tries, 1) + 1):
            samples, background = run_reps(binary, cfg, reps)
            if background is None or background <= args.max_background or attempt == args.tries:
                break
            print(f"{label(cfg):<22} other processes kept {background:.2f} CPUs busy; again",
                  flush=True)
            wait_idle(args.wait_idle)
        med = medians(samples, PRIMARY[cfg["mode"]])
        results.append(dict(config=cfg, samples=samples, median=med, attempts=attempt,
                            background_cpus=None if background is None else round(background, 3)))
        shown = ", ".join(f"{k}={v:,.0f}" for k, v in med.items())
        bg = "" if background is None else f"  (background {background:.2f} CPUs)"
        print(f"{label(cfg):<22} {shown}{bg}", flush=True)
    floor = None
    if args.floor or args.floor_only:
        floor = run_floor(build_floor(args.cc, args.out), reps, args.quick)
        for f in floor:
            what = " ".join(f"{k}={v}" for k, v in f["what"].items())
            print(f"floor {what:<40} {f['key']}={f['median']:,.1f}", flush=True)
    after = load1()
    data = dict(
        meta=dict(date=time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()), commit=git_head(),
                  goose=goose_version(exe), cc=args.cc, cpu=cpu_model(),
                  cpus=os.cpu_count(), os=f"{platform.system()} {platform.release()} {platform.machine()}",
                  reps=reps, quick=args.quick,
                  load_before=None if before is None else round(before, 2),
                  load_after=None if after is None else round(after, 2)),
        results=results, floor=floor)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    tables = render(data)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(tables + "\n", encoding="utf-8")
    print()
    print(tables)


if __name__ == "__main__":
    main()
