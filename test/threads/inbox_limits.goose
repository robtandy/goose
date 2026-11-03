// Inbox limits (§11.2): qlimit_inbox<T>(n) limits every thread's inbox of T
// to n messages, each inbox on its own, and qlimit<T> limits only the
// global queue. A limit is the type's, set before any worker exists; a
// lowered one keeps what is queued, and puts are refused until fewer than
// it remain. Eight putters fill main's inbox while the limit switches
// between 4 and 64: exactly as many puts are taken as the limit allows,
// none refused before the inbox is full, none past it.
struct Item { from: i64, n: i64 }
struct Turn { tries: i64 }
struct Done { ok: i64 }
struct Go { at: i64 }

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

// Puts `tries` items in main's inbox at each turn, saying how many it took.
thread_fn putter(i: i64) {
    loop {
        let t = take<Turn>();
        if t.tries < 0 { break; }
        var ok = 0;
        for k in t.tries {
            if qput_to(-1, Item { from: i, n: k }) { ok++; }
        }
        qput(Done { ok: ok });
    }
}

thread_fn idle() { take<Go>(); }

// A turn for each putter, the first `n` putting `tries` each: how many of
// their puts main's inbox took.
fn turn(putters: const i64[:], n: i64, tries: i64) -> i64 {
    for i in putters.len { qput_to(putters[i], Turn { tries: if i < n { tries } else { 0 } }); }
    var ok = 0;
    for p in putters { ok += take<Done>().ok; }
    ok
}

fn drain(n: i64) -> i64 {
    var got = 0;
    for i in n {
        let x, ok = qpoll<Item>();
        if ok { got++; }
    }
    got
}

fn main() {
    qlimit_inbox<Item>(4);
    var putters: i64[>..] = [];
    for i in 8 { putters.push(thread_spawn(putter, i)); }
    var bad = 0;
    for round in 400 {
        let limit = if round % 2 == 0 { 4 } else { 64 };
        qlimit_inbox<Item>(limit);
        // Exactly `limit` puts, all taken; then one more each, all refused.
        let n = if limit == 4 { 4 } else { 8 };
        if turn(putters, n, limit / n) != limit { bad++; }
        if turn(putters, 8, 1) != 0 { bad++; }
        if limit == 64 {
            // Lowered below what is queued: refused until fewer than 4 remain.
            qlimit_inbox<Item>(4);
            if turn(putters, 8, 1) != 0 { bad++; }
            if drain(61) != 61 { bad++; }
            if turn(putters, 8, 1) != 1 { bad++; }
        }
        if drain(4) != 4 { bad++; }
        let x, left = qpoll<Item>();
        if left { bad++; }
    }
    print("400 rounds of eight putters, limits 4 and 64: ", bad, " wrong");
    for p in putters { qput_to(p, Turn { tries: -1 }); }
    for p in putters { thread_wait(p); }

    // Each inbox has the limit, each its own; the global queue has none.
    qlimit_inbox<Item>(3);
    let a = thread_spawn(idle);
    let b = thread_spawn(idle);
    var ra: bool[5] = [false; 5];
    var rb: bool[5] = [false; 5];
    var rm: bool[5] = [false; 5];
    var rg: bool[5] = [false; 5];
    for i in 5 {
        ra[i] = qput_to(a, Item { from: -1, n: i });
        rb[i] = qput_to(b, Item { from: -1, n: i });
        rm[i] = qput_to(-1, Item { from: -1, n: i });
        rg[i] = qput(Item { from: -1, n: i });
    }
    print("a ", ra, ", b ", rb, ", main ", rm, ", global ", rg);
    qput_to(a, Go { at: 0 });
    qput_to(b, Go { at: 0 });
    thread_wait(a);
    thread_wait(b);
    print("main takes ", drain(10), ": its inbox's 3, then the global queue's 5");
}
