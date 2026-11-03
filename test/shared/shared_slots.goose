// runtime-define: GS_SHARED_STATS=1
// The dynamic stacks' slots are recycled, not unmapped (§11.4): arenas
// built and dropped over and over, each freezing two arrays and an empty
// one, take the slots the last one released, so the program opens three
// slots in 200 rounds, and an empty array takes none; a worker's dynamic
// stacks' slots go back as it ends, and those it froze with the arena they
// are in. ds.items.check_length(n) refuses a length its slot cannot hold,
// before anything grows, as a limit a program can recover from does in a
// contained worker. trim_memory gives the free slots' pages back. The
// report at the end counts the slots opened and reused (GS_SHARED_STATS).
import os;

struct Row { key: i64, payload: i64 }
struct Out { arena: resource<shared>, rows: resource<frozen<Row>> }

fn round(k: i64) -> i64 {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    for i in 1000 { ds.items.push(Row { key: k, payload: i }); }
    let a = sh.freeze(ds);
    let none = sh.freeze(ds);
    for i in 10 { ds.items.push(Row { key: -k, payload: i }); }
    let b = sh.freeze(ds);
    sh.view(a)[999].payload + sh.view(b)[9].payload + sh.view(none).len
}

// Holds its slots until main has every worker's array, so that the slots
// opened are the same however the workers run.
thread_fn builder(arena: resource<shared>) {
    let sh = attach(arena);
    var ds = dynamic_stack<Row> {};
    var spare = dynamic_stack<Row> {};
    for i in 100 { ds.items.push(Row { key: 1, payload: i }); }
    spare.items.push(Row { key: 2, payload: 0 });
    qput(Out { arena: arena, rows: sh.freeze(ds) });
    qget<bool>();
}

thread_fn too_long(n: i64) {
    var ds = dynamic_stack<Row> {};
    print("asking for ", n, " rows");
    print(ds.items.check_length(n));
}

// The message up to its location.
fn located(msg: u8[:]) -> i64 {
    var i = msg.len;
    while i > 0 && msg[i - 1] != '(' { i--; }
    if i < 2 { return msg.len; }
    i - 2
}

fn main() {
    var s = 0;
    for k in 200 { s += round(k); }
    print("200 rounds: ", s);
    let sh = shared {};
    var ids: i64[>..] = [];
    for w in 4 { ids.push(thread_spawn(builder, sh.handle)); }
    var n = 0;
    for w in 4 { n += sh.view(qget<Out>().rows).len; }
    for w in 4 { qput(true); }
    for id in ids { thread_wait(id); }
    print("4 workers froze ", n, " rows");
    var why: u8[>..] = [];
    let ok = thread_wait(thread_spawn_contained(too_long, 1 << 40), why);
    print("check_length: ", ok, " ", why[..located(why)]);
    print("trim_memory: ", trim_memory());
    var after = dynamic_stack<Row> {};
    after.items.push(Row { key: 3, payload: 4 });
    print("a dynamic stack on a trimmed slot: ", after.items[0].payload);
}
