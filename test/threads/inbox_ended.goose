// Puts racing workers' ends (§11.2). A worker's end closes its inboxes and
// discards what it never took, and its record goes to a later worker; a
// put lands before the inbox closes or is refused, so no message reaches a
// later owner of the record, and once the worker has ended every put to it
// is false. A racer keeps putting to a thousand short-lived targets, the
// ended ones too, while main spawns them; each target counts the messages
// that do not name it.
struct Msg { to: i64, n: i64 }
struct Stop { at: i64 }
struct Tally { bad: i64 }
struct Target { id: i64 }
struct Final { taken: i64 }
enum In { M { m: Msg }, S { s: Stop } }

thread_fn target() {
    var bad = 0;
    loop {
        let msg, got = select<In>(60000);
        assert(got);
        match msg {
            M m => { if m.m.to != thread_id() { bad++; } },
            S s => { break; },
        }
    }
    qput(Tally { bad: bad });
}

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

// Main names each target as it spawns it, and -1 when every one has ended:
// then a put to each must be refused.
thread_fn racer() {
    var ids: i64[>..] = [];
    var n = 0;
    loop {
        var done = false;
        loop {
            let t, ok = qpoll<Target>();
            if !ok { break; }
            if t.id < 0 { done = true; break; }
            ids.push(t.id);
        }
        if done { break; }
        let from = if ids.len > 8 { ids.len - 8 } else { 0 };
        for i in from..ids.len {
            qput_to(ids[i], Msg { to: ids[i], n: n });
            n++;
        }
    }
    var taken = 0;
    for id in ids {
        if qput_to(id, Msg { to: id, n: -1 }) { taken++; }
    }
    qput(Final { taken: taken });
}

fn main() {
    let r = thread_spawn(racer);
    var targets: i64[>..] = [];
    for i in 1000 {
        let t = thread_spawn(target);
        targets.push(t);
        qput_to(r, Target { id: t });
        qput_to(t, Msg { to: t, n: -2 });
        qput_to(t, Stop { at: i });
    }
    var bad = 0;
    for t in targets { bad += take<Tally>().bad; }
    for t in targets { thread_wait(t); }
    qput_to(r, Target { id: -1 });
    let f = take<Final>();
    thread_wait(r);
    print("1000 targets, messages for another: ", bad, "; puts taken once all had ended: ",
          f.taken);
}
