// Handles of frozen arrays cross threads as values (§3.12, §11.4): through
// a queue from worker to worker, each freezing what the last one froze and
// one more element; on their own and in a frozen directory of handles,
// which a worker given the directory's handle by a queue walks; and with a
// worker's own arena, which main attaches to before the worker's
// attachment ends and keeps. Each array is read where it was frozen.
import std;

struct Hop { arena: resource<shared>, data: resource<frozen<i64>>, step: i64 }
// Each hop's array, for main; the last one's, which no worker takes.
struct Logged { step: i64, data: resource<frozen<i64>> }
struct Last { data: resource<frozen<i64>> }
struct Made { arena: resource<shared>, data: resource<frozen<i64>> }

let HOPS = 8;

// One hop of the relay: whatever hop comes, its array and one more
// element, frozen into the same arena, to whichever worker takes it next.
thread_fn relay() {
    let h = qget<Hop>();
    let sh = attach(h.arena);
    var ds = dynamic_stack<i64> {};
    ds.items.append(sh.view(h.data));
    ds.items.push(h.step * 10);
    let r = sh.freeze(ds);
    qput(Logged { step: h.step, data: r });
    if h.step < HOPS { qput(Hop { arena: h.arena, data: r, step: h.step + 1 }); }
    else { qput(Last { data: r }); }
}

// The directory's arrays' sums, through a handle of a handle.
thread_fn summer(arena: resource<shared>) {
    let sh = attach(arena);
    let dir = qget<resource<frozen<resource<frozen<i64>>>>>();
    var s = 0;
    for r in sh.view(dir) { for x in sh.view(r) { s += x; } }
    qput(s);
}

// An arena of the worker's own, with an array in it, handed to main.
thread_fn maker(n: i64) {
    let sh = shared {};
    var ds = dynamic_stack<i64> {};
    for i in n { ds.items.push(i * i); }
    qput(Made { arena: sh.handle, data: sh.freeze(ds) });
    qget<bool>();   // main has attached
}

fn main() {
    let sh = shared {};
    var first = dynamic_stack<i64> {};
    first.items.push(-1);
    var ids: i64[>..] = [];
    for w in HOPS { ids.push(thread_spawn(relay)); }
    qput(Hop { arena: sh.handle, data: sh.freeze(first), step: 1 });
    let last = qget<Last>();
    for id in ids { thread_wait(id); }
    print("after ", HOPS, " hops: ", sh.view(last.data), " (", last.data, ")");

    // Every hop's array, by its handle, frozen as a directory in hop order.
    var logged: Logged[>..] = [];
    for k in HOPS { logged.push(qget<Logged>()); }
    var hops = dynamic_stack<resource<frozen<i64>>> {};
    for k in HOPS { for l in logged { if l.step == k + 1 { hops.items.push(l.data); } } }
    let dir = sh.freeze(hops);
    let id = thread_spawn(summer, sh.handle);
    qput(dir);
    print("a worker's sum of the directory's arrays: ", qget<i64>());
    thread_wait(id);

    let mid = thread_spawn(maker, 6);
    let made = qget<Made>();
    let theirs = attach(made.arena);
    qput(true);
    thread_wait(mid);
    print("the worker's array, after it ended: ", theirs.view(made.data));
}
