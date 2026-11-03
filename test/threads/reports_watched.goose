// Watched workers that abort (§11.2): a contained worker's abort ends it as
// a return does, so its inboxes close, puts to it are false, and the
// watches on it fire once what it put is queued, with thread_wait
// answering at once. Main collects replies and ends in one select, as a
// supervisor does; a worker blocked in select hears of its peer's abort;
// and a worker blocked in select aborts on what it takes.
struct Job { key: i64 }
struct Reply { key: i64, value: i64, by: i64 }
struct Ended { id: i64 }
struct Poison { at: i64 }
struct Heard { replies: i64, peer: i64 }
enum Collect { Reply { r: Reply }, Ended { e: Ended } }
enum WorkIn { Job { j: Job }, Poison { p: Poison } }

// What must come: a minute without it fails rather than hangs.
fn next<E>() -> E {
    let m, got = select<E>(60000);
    assert(got);
    m
}
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

// Serves jobs until a negative key, a stop queued behind them in one queue:
// select takes types by turns, so what must come after the jobs is a job
// too. `bad` fails its third; a poison, whenever it comes, fails any.
thread_fn serve(bad: bool) {
    loop {
        match next<WorkIn>() {
            Job j => {
                if j.j.key < 0 { break; }
                assert(!(bad && j.j.key == 3));
                qput_to(-1, Reply { key: j.j.key, value: j.j.key * 2, by: thread_id() });
            },
            Poison p => { assert(false); },
        }
    }
}

// Sends one reply to `to`, then fails.
thread_fn fails_after_one(to: i64) {
    qput_to(to, Reply { key: 1, value: 2, by: thread_id() });
    assert(false);
}

// Watches a peer and takes its replies until its end, then tells main.
thread_fn listens() {
    let peer = thread_spawn_contained(fails_after_one, thread_id());
    thread_watch(peer, Ended { id: peer });
    var replies = 0;
    loop {
        match next<Collect>() {
            Reply r => { replies++; },
            Ended e => { break; },
        }
    }
    qput_to(-1, Heard { replies: replies, peer: peer });
}

fn main() {
    // A supervisor: four contained workers, one failing its third job.
    var ids: i64[>..] = [];
    for i in 4 {
        let id = thread_spawn_contained(serve, i == 2);
        thread_watch(id, Ended { id: id });
        ids.push(id);
    }
    for id in ids {
        for k in 5 { qput_to(id, Job { key: k + 1 }); }
        qput_to(id, Job { key: -1 });
    }
    var replies = 0;
    var ended = 0;
    var why: u8[>..] = [];
    while ended < 4 {
        match next<Collect>() {
            Reply r => { replies++; },
            Ended e => {
                ended++;
                why.clear();
                if !thread_wait(e.e.id, why) {
                    print("worker ", e.e.id == ids[2], " aborted: ", why.len > 0);
                    print("a put to it: ", qput_to(e.e.id, Job { key: 9 }));
                }
            },
        }
    }
    loop {
        let m, got = select<Collect>(0);
        if !got { break; }
        replies++;
    }
    print("replies, all queued by their workers' ends: ", replies);

    // A contained worker in select hears that its contained peer aborted.
    let l = thread_spawn_contained(listens);
    let h = take<Heard>();
    print("its peer's reply: ", h.replies, ", its peer returned: ", thread_wait(h.peer),
          ", it returned: ", thread_wait(l));

    // A contained worker blocked in select aborts on what it takes.
    let p = thread_spawn_contained(serve, false);
    thread_watch(p, Ended { id: p });
    qput_to(p, Job { key: 1 });
    qput_to(p, Poison { at: 0 });
    let r = take<Reply>();
    let e = take<Ended>();
    why.clear();
    print("served ", r.key, ", then ended: ", e.id == p, ", returned: ", thread_wait(p, why),
          ", a put to it: ", qput_to(p, Job { key: 2 }));
    print(why.len > 0);
}
