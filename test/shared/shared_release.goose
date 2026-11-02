// runtime-define: GS_SHARED_STATS=1
// An attachment ends at every exit of its scope (§11.4): a block's end, a
// loop's iteration, break, continue, return and return ... from, after the
// defer bodies declared after it, which still view through it; and a
// contained worker that aborts holding attachments and views has them
// ended, so that the program goes on. An arena is released when its last
// attachment ends: a contained worker's attach of its handle then aborts,
// which `released` asks. The report at the end (GS_SHARED_STATS) counts
// what was made and released.
import os;

let DIR = "gs_shared_release";

fn path() -> u8[>..] { str(DIR, "/col.i64") }

thread_fn probe(h: resource<shared>) {
    let sh = attach(h);
}

fn released(h: resource<shared>) -> bool { !thread_wait(thread_spawn_contained(probe, h)) }

// A worker that views main's mapping, and aborts with its attachments live.
thread_fn holder(h: resource<shared>, m: resource<mapping>) {
    let sh = attach(h);
    let again = attach(h);
    let xs = view<i64>(again, m, 0, 4);
    print("holder sees ", xs[3]);
    assert(xs[0] < 0);
}

// The message up to its location.
fn located(msg: u8[:]) -> i64 {
    var i = msg.len;
    while i > 0 && msg[i - 1] != '(' { i--; }
    if i < 2 { return msg.len; }
    i - 2
}

fn early(hs: resource<shared>[>..]&, k: i64) -> i64 {
    let sh = shared {};
    hs.push(sh.handle);
    if k > 0 { return k; }
    let inner = shared {};
    hs.push(inner.handle);
    0
}

recursive fn deep(hs: resource<shared>[>..]&, k: i64) -> i64 {
    let sh = shared {};
    hs.push(sh.handle);
    if k == 0 { return 7 from outer; }
    deep(hs, k - 1) + 1
}

fn outer(hs: resource<shared>[>..]&) -> i64 { deep(hs, 3) }

fn main() {
    make_dir(DIR);
    var col: i64[>..] = [];
    for i in 16 { col.push(i * 10 + 1); }
    write_file(path(), bytes_of(col));

    // A block's end.
    let h = {
        let sh = shared {};
        let m, ok = sh.map_file(path());
        print("block: ", view<i64>(sh, m, 8, 1)[0]);
        sh.handle
    };
    print("released after its block: ", released(h));

    // Each iteration's, and a break's and a continue's.
    var hs: resource<shared>[>..] = [];
    for i in 4 {
        let sh = shared {};
        hs.push(sh.handle);
        if i == 1 { continue; }
        if i == 2 { break; }
    }
    var n = 0;
    for x in hs { if released(x) { n += 1; } }
    print("released after the loop: ", n, " of ", hs.len);

    // A return, and a return ... from out of a recursion.
    hs.clear();
    print(early(hs, 1), " ", early(hs, 0), " ", outer(hs));
    n = 0;
    for x in hs { if released(x) { n += 1; } }
    print("released after returns: ", n, " of ", hs.len);

    // A defer declared after an attachment runs while it is attached.
    let dh = {
        let sh = shared {};
        let m, ok = sh.map_file(path());
        defer { print("defer views ", view<i64>(sh, m, 120, 1)[0]); }
        sh.handle
    };
    print("released after the defer: ", released(dh));

    // A contained worker aborts holding two attachments and a view; then
    // main's attachment is the last, and its end releases the arena.
    let ah = {
        let sh = shared {};
        let m, ok = sh.map_file(path());
        var why: u8[>..] = [];
        let id = thread_spawn_contained(holder, sh.handle, m);
        print("holder returned: ", thread_wait(id, why));
        print(why[..located(why)]);
        print("still attached here: ", !released(sh.handle), " ", view<i64>(sh, m, 0, 1)[0]);
        sh.handle
    };
    print("released after the abort: ", released(ah));

    delete_file(path());
    delete_dir(DIR);
}
