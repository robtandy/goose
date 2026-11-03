// thread_watch(id, v) (§11.2) puts a copy of v in the caller's inbox when
// worker id ends: at once if it has, exactly once if it is ending, after
// all it put is queued and thread_wait would answer at once, and even into
// a full inbox. Any thread may watch any worker any number of times; a
// watch dies with its watcher. Ten thousand workers fire a watch each, once
// each, and ten thousand more live, watch and end in a chain.
struct Ended { id: i64 }
struct Tag { id: i64, k: i64 }
struct Go { at: i64 }
struct Last { n: i64 }
struct Seen { by: i64, id: i64 }

thread_fn quick() {}

thread_fn waits() { qget<Go>(); }

// What a worker puts is queued before its watches fire.
thread_fn puts_then_ends(n: i64) {
    for i in n { qput(Last { n: i }); }
}

// Watches `target` for main, and says so when the watch fires.
thread_fn watcher(target: i64) {
    thread_watch(target, Ended { id: target });
    qput(Seen { by: thread_id(), id: take<Ended>().id });
}

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

// Watches the worker before it in the chain, and ends: its watch is
// cancelled, or fires into its inbox, open or closed.
thread_fn link(prev: i64) {
    if prev >= 0 { thread_watch(prev, Ended { id: prev }); }
}

fn main() {
    // A worker that has ended: the message at once.
    let a = thread_spawn(quick);
    thread_wait(a);
    thread_watch(a, Ended { id: a });
    let ea, gota = qpoll<Ended>();
    print("ended before the watch: ", gota && ea.id == a);

    // A running one: its watches fire as it ends, each once, after what it
    // put and with thread_wait answering at once.
    let b = thread_spawn(waits);
    thread_watch(b, Ended { id: b });
    thread_watch(b, Tag { id: b, k: 1 });
    thread_watch(b, Tag { id: b, k: 2 });
    let eb0, gotb0 = qpoll<Ended>();
    print("while it runs: ", gotb0);
    qput_to(b, Go { at: 0 });
    print("when it ends: ", take<Ended>().id == b, ", thread_wait ", thread_wait(b));
    let t1 = take<Tag>();
    let t2 = take<Tag>();
    let t3, gott3 = qpoll<Tag>();
    print("its tags: ", t1.k + t2.k, " ", t1.id == b && t2.id == b, ", once each: ", !gott3);

    let c = thread_spawn(puts_then_ends, 100);
    thread_watch(c, Ended { id: c });
    take<Ended>();
    var queued = 0;
    for i in 100 {
        let l, ok = qpoll<Last>();
        if ok { queued++; }
    }
    print("what it put, queued before its end's message: ", queued);

    // Into a full inbox: a watch's message is queued past the limit, and
    // counts while it waits.
    qlimit_inbox<Ended>(1);
    let d = thread_spawn(waits);
    for i in 3 { thread_watch(d, Ended { id: d }); }
    qput_to(d, Go { at: 0 });
    thread_wait(d);
    let first3 = take<Ended>();
    print("a put while two more wait: ", qput_to(-1, Ended { id: -5 }));
    var full = if first3.id == d { 1 } else { 0 };
    for i in 2 {
        let ed, ok = qpoll<Ended>();
        if ok && ed.id == d { full++; }
    }
    print("three watches past a limit of one: ", full);
    print("and once they are taken: ", qput_to(-1, Ended { id: -5 }));
    take<Ended>();
    qlimit_inbox<Ended>(1000000);

    // Any thread may watch: four watchers of one worker each hear of it.
    let t = thread_spawn(waits);
    var ws: i64[>..] = [];
    for i in 4 { ws.push(thread_spawn(watcher, t)); }
    for w in ws {
        // Each watches before t ends, or after: either way, once.
        thread_watch(w, Tag { id: w, k: 0 });
    }
    qput_to(t, Go { at: 0 });
    var seen = 0;
    for w in ws {
        let s = take<Seen>();
        if s.id == t { seen++; }
    }
    for w in ws { take<Tag>(); }
    print("watchers of one worker: ", seen);

    // Ten thousand fires, in batches of a hundred, each once.
    var fired: u8[>..] = [];
    fired.resize(20000, 0);
    var first = -1;
    var wrong = 0;
    for batch in 100 {
        var ids: i64[>..] = [];
        for i in 100 {
            let id = if i % 2 == 0 { thread_spawn(quick) } else { thread_spawn(waits) };
            if first < 0 { first = id; }
            thread_watch(id, Ended { id: id });
            ids.push(id);
        }
        for i in 100 { if i % 2 == 1 { qput_to(ids[i], Go { at: 0 }); } }
        for i in 100 {
            let e = take<Ended>();
            let k = e.id - first;
            if k < 0 || k >= fired.len { wrong++; } else { fired[k] += 1; }
        }
        for id in ids { thread_wait(id); }
    }
    var once = 0;
    for f in fired { if f == 1 { once++; } else if f > 1 { wrong++; } }
    let extra, gotextra = qpoll<Ended>();
    print("10000 workers watched: ", once, " fired once, ", wrong, " wrong, more: ", gotextra);

    // Ten thousand short-lived watchers of short-lived workers, in a chain:
    // nothing reaches main.
    var prev = -1;
    for i in 10000 {
        let id = thread_spawn(link, prev);
        if i % 1000 == 999 { thread_wait(id); }
        prev = id;
    }
    thread_wait(prev);
    let stray, gotstray = qget<Ended>(20);
    print("a chain of 10000: nothing for main: ", !gotstray);
}
