// Read-only dictionaries from main to every worker (§11.4): main builds two
// tables on dynamic stacks and freezes them, an open-addressing table of
// i64 keys and one of byte-string keys in three regions, the keys' bytes,
// their slots and a directory of the two; 16 workers given the handles as
// arguments, and 4 through a queue, attach and look every key up in place.
// The integer probe is `checkfree`: std's hash is, and `%` by the table's
// length proves each slot's index. Every worker's sums are main's own.
import std;

struct Slot { key: i64, value: i64, used: bool }
// A byte-string key's bytes, at `start` of the bytes region, and its value;
// a free slot has len -1.
struct Name { start: i64, len: i64, value: i64 }
// The string table's directory: the handles of its two other regions.
struct Names { bytes: resource<frozen<u8>>, slots: resource<frozen<Name>> }
struct Dicts { arena: resource<shared>, ints: resource<frozen<Slot>>, names: resource<frozen<Names>> }
struct Sums { worker: i64, ints: i64, names: i64 }

let NKEYS = 500;

fn home(h: u64, n: i64) -> i64 { ((h >> 1) as! i64) % n }

// The value of key in slots, or -1: probed from its home slot on.
checkfree fn find(slots: const Slot[:], key: i64) -> i64 {
    let h = (hash(key) >> 1) as! i64;
    let first = h % slots.len;
    for k in slots.len {
        let s = slots[(first + k) % slots.len];
        if !s.used { return -1; }
        if s.key == key { return s.value; }
    }
    -1
}

fn find_name(slots: const Name[:], bytes: const u8[:], key: u8[:]) -> i64 {
    var i = home(hash(key), slots.len);
    loop {
        let s = slots[i];
        if s.len < 0 { return -1; }
        if bytes[s.start..s.start + s.len] == key { return s.value; }
        i = (i + 1) % slots.len;
    }
}

fn name(i: i64) -> u8[>..] { str("key-", i * 37 % 1009, "-", i) }

// Every key's lookup, and some that miss, through this thread's views.
fn sums(sh: shared&, d: Dicts) -> Sums {
    let ints = sh.view(d.ints);
    let dir = sh.view(d.names)[0];
    let slots = sh.view(dir.slots);
    let bytes = sh.view(dir.bytes);
    var s = Sums { worker: 0, ints: 0, names: 0 };
    for i in NKEYS + 50 {
        let v = find(ints, i * 3);
        if v >= 0 { s.ints += v; }
        let w = find_name(slots, bytes, name(i));
        if w >= 0 { s.names += w; }
    }
    s
}

thread_fn reader(w: i64, d: Dicts) {
    let sh = attach(d.arena);
    var s = sums(sh, d);
    s.worker = w;
    qput(s);
}

thread_fn queued_reader(w: i64) {
    let d = qget<Dicts>();
    let sh = attach(d.arena);
    var s = sums(sh, d);
    s.worker = w;
    qput(s);
}

// The tables, built in place on dynamic stacks and frozen into sh's arena.
fn build(sh: shared&) -> Dicts {
    var ints = dynamic_stack<Slot> {};
    for i in 2 * NKEYS { ints.items.push(Slot { key: 0, value: 0, used: false }); }
    for i in NKEYS {
        var j = home(hash(i * 3), ints.items.len);
        while ints.items[j].used { j = (j + 1) % ints.items.len; }
        ints.items[j] = Slot { key: i * 3, value: i, used: true };
    }
    var bytes = dynamic_stack<u8> {};
    var slots = dynamic_stack<Name> {};
    for i in 2 * NKEYS { slots.items.push(Name { start: 0, len: -1, value: 0 }); }
    for i in NKEYS {
        let k = name(i);
        var j = home(hash(k), slots.items.len);
        while slots.items[j].len >= 0 { j = (j + 1) % slots.items.len; }
        slots.items[j] = Name { start: bytes.items.len, len: k.len, value: i * 2 };
        bytes.items.append(k);
    }
    var dir = dynamic_stack<Names> {};
    dir.items.push(Names { bytes: sh.freeze(bytes), slots: sh.freeze(slots) });
    Dicts { arena: sh.handle, ints: sh.freeze(ints), names: sh.freeze(dir) }
}

fn main() {
    let sh = shared {};
    let d = build(sh);
    let want = sums(sh, d);
    print("main: ", want.ints, " ", want.names);
    var ids: i64[>..] = [];
    for w in 16 { ids.push(thread_spawn(reader, w, d)); }
    for w in 4 {
        ids.push(thread_spawn(queued_reader, 16 + w));
        qput(d);
    }
    var same = 0;
    for w in 20 {
        let s = qget<Sums>();
        if s.ints == want.ints && s.names == want.names { same += 1; }
    }
    for id in ids { thread_wait(id); }
    print("workers whose lookups match main's: ", same, " of 20");
}
