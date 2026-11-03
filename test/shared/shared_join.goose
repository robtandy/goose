// runtime-define: GS_SHARED_STATS=1
// The three-phase radix-partitioned hash join of docs/design/
// shared_memory.md, section 6, on frozen regions (§11.4): workers partition
// their morsels of the build side, two mapped columns, onto dynamic stacks
// of their own and freeze them; each builds partitions' tables, chained by
// self-relative links, from every worker's frozen partitions, and freezes
// each; then every worker probes its morsels of the probe side against every
// frozen table. W = 1, 2, 4 and 16 workers and P = W and 4W partitions, each
// join in an arena of its own, whose end releases what the join froze and
// hands its slots to the next: the matches and the payloads' sum are what a
// single-threaded reference finds. The four last workers of 16 have no
// build morsel, and freeze empty arrays, which take no slot. The report at
// the end (GS_SHARED_STATS) counts what was made and released.
import std;
import os;
import dictionary;

struct Row { key: i64, payload: i64 }
// A run of one partition's rows in a worker's partitioned rows.
struct Run { part: i64, start: i64, count: i64 }
// A table: its first `heads` entries are the chain heads, the rest its rows,
// linked by self-relative references within the one frozen array.
struct Entry { key: i64, payload: i64, next: Entry&<u32>? }
struct Result { matches: i64, sum: i64 }

// What every worker is given: the arena, the mapped columns and their sizes,
// the partitions, the workers and which one it is.
struct Job {
    arena: resource<shared>,
    bkeys: resource<mapping>, bpays: resource<mapping>, pkeys: resource<mapping>,
    nbuild: i64, nprobe: i64, parts: i64, workers: i64, worker: i64,
}
struct Partitioned { rows: resource<frozen<Row>>, runs: resource<frozen<Run>> }
// Phase 2's work: partition `part` from every worker's frozen partitions;
// part < 0 ends the phase.
struct Task { part: i64, inputs: resource<frozen<Partitioned>> }
struct Built { part: i64, table: resource<frozen<Entry>>, heads: i64 }

let DIR = "gs_shared_join";
let MORSEL = 1000;

// A multiplicative hash, kept non-negative so that `h % n` is an index.
checkfree inline fn mix(k: i64) -> i64 { ((k as! u64) * 0x9E3779B97F4A7C15 >> 1) as! i64 }

// Phase 1: a full (or the last) buffer of partition p, appended as a run.
checkfree fn flush(buf: Row[..64]&, p: i64, rows: Row[>..]&, runs: Run[>..]&) {
    runs.push(Run { part: p, start: rows.len, count: buf.len });
    rows.append(buf);
    buf.clear();
}

// Phase 1: one morsel's rows, from two views of the same rows, into the
// partitions' write-combining buffers.
checkfree fn scatter(keys: const i64[:], pays: const i64[:], bufs: Row[..64][>..]&,
                     rows: Row[>..]&, runs: Run[>..]&) {
    assert(pays.len == keys.len);
    for i in keys.len {
        let h = mix(keys[i]);
        let p = h % bufs.len;
        bufs[p].push(Row { key: keys[i], payload: pays[i] });
        if bufs[p].len == bufs[p].cap { flush(bufs[p], p, rows, runs); }
    }
}

// Phase 1: this worker's morsels of the build side, partitioned privately
// onto its two dynamic stacks' items.
fn partition(sh: shared&, job: Job&, rows: Row[>..]&, runs: Run[>..]&) {
    var bufs: Row[..64][>..] = [];
    for p in job.parts { bufs.push([]); }
    var first = job.worker * MORSEL;
    while first < job.nbuild {
        let n = min(MORSEL, job.nbuild - first);
        scatter(view<i64>(sh, job.bkeys, first * 8, n), view<i64>(sh, job.bpays, first * 8, n),
                bufs, rows, runs);
        first += job.workers * MORSEL;
    }
    for p in bufs.len { if bufs[p].len > 0 { flush(bufs[p], p, rows, runs); } }
}

// Phase 2: rows of one partition into its table, whose first `heads`
// entries are the chain heads.
checkfree fn insert(t: Entry[>..]&, heads: i64, rows: const Row[:]) {
    assert(heads > 0 && heads <= t.len);
    for r in rows {
        let h = mix(r.key) >> 7;
        let b = h % heads;
        let e .= t.push(Entry { key: r.key, payload: r.payload, next: t[b].next });
        t[b].next .= e;
    }
}

// Phase 2: partition `part`'s table, from every worker's frozen rows.
fn build(sh: shared&, inputs: const Partitioned[:], part: i64, t: Entry[>..]&) -> i64 {
    var n = 0;
    for w in inputs { for r in sh.view(w.runs) { if r.part == part { n += r.count; } } }
    let heads = next_pow2(max(n, 1));
    for i in heads { t.push(Entry { key: 0, payload: 0, next: null }); }
    for w in inputs {
        let rows = sh.view(w.rows);
        for r in sh.view(w.runs) {
            if r.part == part { insert(t, heads, rows[r.start..r.start + r.count]); }
        }
    }
    heads
}

// Phase 3: every probe key against its partition's table. The links in a
// table's heads reach its rows past the cut.
checkfree fn probe(tables: const (const Entry[:])[:], keys: const i64[:], res: Result&) {
    for k in keys {
        let h = mix(k);
        let t = tables[h % tables.len];
        let b = h >> 7;
        var e = t[b % t.len].next;
        while e {
            if e.key == k {
                res.matches += 1;
                res.sum += e.payload;
            }
            e .= e.next;
        }
    }
}

// Phase 3: this worker's morsels of the probe side against every table.
fn probe_all(sh: shared&, job: Job&, tables: const (const Entry[:])[:]) -> Result {
    var res = Result { matches: 0, sum: 0 };
    var first = job.worker * MORSEL;
    while first < job.nprobe {
        let n = min(MORSEL, job.nprobe - first);
        probe(tables, view<i64>(sh, job.pkeys, first * 8, n), res);
        first += job.workers * MORSEL;
    }
    res
}

thread_fn join_worker(job: Job) {
    let sh = attach(job.arena);                          // one attachment, three phases
    var rows = dynamic_stack<Row> {};
    var runs = dynamic_stack<Run> {};
    partition(sh, job, rows.items, runs.items);          // views of the build morsels
    qput(Partitioned { rows: sh.freeze(rows), runs: sh.freeze(runs) });
    var t = dynamic_stack<Entry> {};
    loop {
        let task = qget<Task>();
        guard task.part >= 0 else { break; }
        let heads = build(sh, sh.view(task.inputs), task.part, t.items);
        qput(Built { part: task.part, table: sh.freeze(t), heads: heads }); // t is empty again
    }
    var tables: (const Entry[:])[..1024] = [];
    for b in sh.view(qget<resource<frozen<Built>>>()) { tables.push(sh.view(b.table)[..b.heads]); }
    qput(probe_all(sh, job, tables));                    // views of the probe morsels
}

// The join on w workers and p partitions, in an arena of its own that the
// columns are mapped into: main collects each phase's results before it
// queues the next, and freezes the workers' partitions into the tasks'
// directory and the tables in partition order. Its attachment's end, after
// the waits, releases every region of the join.
fn join(nb: i64, np: i64, w: i64, p: i64) -> Result {
    let sh = shared {};
    let bkeys, ok1 = sh.map_file(str(DIR, "/bkeys"));
    let bpays, ok2 = sh.map_file(str(DIR, "/bpays"));
    let pkeys, ok3 = sh.map_file(str(DIR, "/pkeys"));
    assert(ok1 && ok2 && ok3);
    var ids: i64[>..] = [];
    for i in w {
        let job = Job { arena: sh.handle, bkeys: bkeys, bpays: bpays, pkeys: pkeys, nbuild: nb,
                        nprobe: np, parts: p, workers: w, worker: i };
        ids.push(thread_spawn_contained(join_worker, job));
    }
    var dir = dynamic_stack<Partitioned> {};
    for i in w { dir.items.push(qget<Partitioned>()); }
    let inputs = sh.freeze(dir);
    for part in p { qput(Task { part: part, inputs: inputs }); }
    for i in w { qput(Task { part: -1, inputs: inputs }); }
    var came: Built[>..] = [];
    for part in p { came.push(qget<Built>()); }
    var built = dynamic_stack<Built> {};
    for part in p { for b in came { if b.part == part { built.items.push(b); } } }
    let tables = sh.freeze(built);
    for i in w { qput(tables); }
    var res = Result { matches: 0, sum: 0 };
    for i in w {
        let r = qget<Result>();
        res.matches += r.matches;
        res.sum += r.sum;
    }
    for id in ids { assert(thread_wait(id)); }
    res
}

struct Agg { count: i64, sum: i64 }

fn main() {
    make_dir(DIR);
    let nb = 12000;
    let np = 30000;
    var bk: i64[>..] = [];
    var bp: i64[>..] = [];
    var pk: i64[>..] = [];
    var r = rng { s: 7 };
    for i in nb {
        bk.push((rand_u64(r) % 4000) as i64);
        bp.push((rand_u64(r) % 1000000) as i64);
    }
    for i in np { pk.push((rand_u64(r) % 6000) as i64); }
    write_file(str(DIR, "/bkeys"), bytes_of(bk));
    write_file(str(DIR, "/bpays"), bytes_of(bp));
    write_file(str(DIR, "/pkeys"), bytes_of(pk));

    // The single-threaded reference: each build key's count and payload sum.
    var d = dictionary<i64, Agg> {};
    for i in nb {
        let a .= d.get_or_insert(bk[i], Agg { count: 0, sum: 0 });
        a.count += 1;
        a.sum += bp[i];
    }
    var want = Result { matches: 0, sum: 0 };
    for k in pk {
        let a = d.get(k);
        if a {
            want.matches += a.count;
            want.sum += a.sum;
        }
    }
    print("reference: ", want.matches, " matches, payloads summing to ", want.sum);
    for w in [1, 2, 4, 16] {
        for p in [w, 4 * w] { print("W = ", w, ", P = ", p, ": ", join(nb, np, w, p) == want); }
    }
    delete_file(str(DIR, "/bkeys"));
    delete_file(str(DIR, "/bpays"));
    delete_file(str(DIR, "/pkeys"));
    delete_dir(DIR);
}
