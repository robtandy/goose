// runtime-define: GS_SHARED_STATS=1
// Contained workers abort in each phase of a join (docs/design/
// shared_memory.md, section 6, §11.4): in phase 1 holding its two dynamic
// stacks, with their elements, unfrozen; in phase 2 holding the table's
// dynamic stack after freezing its partitions, which its peers then build
// from; in phase 3 holding views of every table. Main learns of the abort
// by waiting for that worker, goes on without its part, and its
// attachment's end releases every region; at the end every dynamic stack
// has ended, every frozen array is released and every slot is free
// (GS_SHARED_STATS). A frozen view of the zero handle, or of a released
// arena's array through another arena's attachment, and an attach of a
// released arena abort with their messages.
import std;

struct Row { key: i64, payload: i64 }
struct Entry { key: i64, payload: i64, next: Entry&<u32>? }
struct Job { arena: resource<shared>, worker: i64, workers: i64, parts: i64, bad: i64, phase: i64 }
struct Partitioned { rows: resource<frozen<Row>> }
struct Task { part: i64, inputs: resource<frozen<Partitioned>> }
struct Built { part: i64, table: resource<frozen<Entry>> }
struct Result { worker: i64, matches: i64 }

let ROWS = 400;

fn fails(job: Job&, phase: i64) {
    if job.worker == job.bad && job.phase == phase { abort(str("phase ", phase)); }
}

// Its share of the rows 0 .. ROWS, keys i % 100, partitioned by key.
fn partition(job: Job&, rows: Row[>..]&) {
    for i in ROWS {
        if i % job.workers == job.worker { rows.push(Row { key: i % 100, payload: i }); }
    }
}

// Partition part's table: one chain per partition, every worker's rows.
fn build(sh: shared&, inputs: const Partitioned[:], part: i64, t: Entry[>..]&) {
    t.push(Entry { key: -1, payload: 0, next: null });
    for w in inputs {
        for r in sh.view(w.rows) {
            if r.key % 4 == part {
                let e .= t.push(Entry { key: r.key, payload: r.payload, next: t[0].next });
                t[0].next .= e;
            }
        }
    }
}

fn count(sh: shared&, tables: const Built[:], keys: i64) -> i64 {
    var n = 0;
    for k in keys {
        var e = sh.view(tables[k % 4].table)[0].next;
        while e {
            if e.key == k { n++; }
            e .= e.next;
        }
    }
    n
}

thread_fn worker(job: Job) {
    let sh = attach(job.arena);
    var rows = dynamic_stack<Row> {};
    var spare = dynamic_stack<i64> {};
    partition(job, rows.items);
    spare.items.push(1);
    fails(job, 1);
    qput(Partitioned { rows: sh.freeze(rows) });
    var t = dynamic_stack<Entry> {};
    fails(job, 2);
    loop {
        let task = qget<Task>();
        guard task.part >= 0 else { break; }
        build(sh, sh.view(task.inputs), task.part, t.items);
        qput(Built { part: task.part, table: sh.freeze(t) });
    }
    let tables = sh.view(qget<resource<frozen<Built>>>());
    let first = sh.view(tables[0].table);
    assert(first.len > 0);
    fails(job, 3);
    qput(Result { worker: job.worker, matches: count(sh, tables, 100) });
}

// The message up to its location.
fn located(msg: u8[:]) -> i64 {
    var i = msg.len;
    while i > 0 && msg[i - 1] != '(' { i--; }
    if i < 2 { return msg.len; }
    i - 2
}

// Four workers and four partitions, worker 1 aborting in `phase` (none for
// 0): main waits for it as soon as it may have aborted, and from then on
// waits for three. The matches every worker found.
fn join(phase: i64) -> i64 {
    let w = 4;
    let p = 4;
    let sh = shared {};
    var ids: i64[>..] = [];
    for i in w {
        ids.push(thread_spawn_contained(worker, Job { arena: sh.handle, worker: i, workers: w,
                                                      parts: p, bad: 1, phase: phase }));
    }
    var live = w;
    let gone = {
        var why: u8[>..] = [];
        let quit = { if phase > 0 && phase < 3 { !thread_wait(ids[1], why) } else { false } };
        if quit {
            print("  worker 1 aborted: ", why[..located(why)]);
            live = w - 1;
        }
        quit
    };
    var dir = dynamic_stack<Partitioned> {};
    for i in (if phase == 1 { w - 1 } else { w }) { dir.items.push(qget<Partitioned>()); }
    let inputs = sh.freeze(dir);
    for part in p { qput(Task { part: part, inputs: inputs }); }
    for i in live { qput(Task { part: -1, inputs: inputs }); }
    var came: Built[>..] = [];
    for part in p { came.push(qget<Built>()); }
    var built = dynamic_stack<Built> {};
    for part in p { for b in came { if b.part == part { built.items.push(b); } } }
    let tables = sh.freeze(built);
    for i in live { qput(tables); }
    if phase == 3 {
        var why: u8[>..] = [];
        if !thread_wait(ids[1], why) {
            print("  worker 1 aborted: ", why[..located(why)]);
            live = w - 1;
        }
    }
    var n = 0;
    for i in live { n += qget<Result>().matches; }
    for k in ids.len { if k != 1 || !gone { thread_wait(ids[k]); } }
    n
}

thread_fn zero_view() {
    let sh = shared {};
    let none = default<resource<frozen<i64>>>();
    print(sh.view(none).len);
}

thread_fn foreign_view(stale: resource<frozen<i64>>) {
    let sh = shared {};
    print(sh.view(stale).len);
}

thread_fn attacher(h: resource<shared>) {
    let sh = attach(h);
}

fn report(what: const u8[:], id: i64) {
    var why: u8[>..] = [];
    let ok = thread_wait(id, why);
    print(what, ": ", ok, " ", why[..located(why)]);
}

fn main() {
    print("no abort: ", join(0), " matches");
    for phase in 1..4 {
        print("an abort in phase ", phase, ":");
        print("  main goes on: ", join(phase), " matches");
    }
    // An array of an arena released when its block ended, and the arena.
    var gone: resource<frozen<i64>>;
    let arena = {
        let sh = shared {};
        var ds = dynamic_stack<i64> {};
        ds.items.push(7);
        gone = sh.freeze(ds);
        sh.handle
    };
    report("a view of the zero handle", thread_spawn_contained(zero_view));
    report("a view of a released arena's array", thread_spawn_contained(foreign_view, gone));
    report("an attach of the released arena", thread_spawn_contained(attacher, arena));
}
