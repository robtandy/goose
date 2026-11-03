// runtime-debug
// References to a dynamic stack's whole array survive its freeze (§5.1,
// §11.4): they name its header and its stack, never a slot, so a local
// alias, one in a holder and a caller's each see ds.items empty after a
// freeze and push onto the fresh slot, while the frozen array keeps what
// was pushed before. A loop pushing through an alias and freezing in the
// same round reloads the base and the top it caches (the -O1 C of
// alias_loop, which the runner reads). The debug build makes each frozen
// array read-only, so a push through a stale base would fault.
struct Row { key: i64, payload: i64 }
struct Holder { items: Row[>..]& }

fn keys(v: const Row[:]) -> i64 {
    var s = 0;
    for r in v { s = s * 10 + r.key; }
    s
}

// A caller's alias: items is the dynamic stack's array.
fn through_caller(sh: shared&, d: dynamic_stack<Row>&, items: Row[>..]&) -> resource<frozen<Row>> {
    items.push(Row { key: 3, payload: 0 });
    let r = sh.freeze(d);
    items.push(Row { key: 4, payload: items.len });
    r
}

// Pushes through an alias of d.items, freezing in the same loop.
fn alias_loop(sh: shared&, d: dynamic_stack<Row>&, rounds: i64) -> resource<frozen<Row>> {
    let out = d.items;
    var r = sh.freeze(d);
    for b in rounds {
        for i in 3 { out.push(Row { key: b, payload: i }); }
        r = sh.freeze(d);
        out.push(Row { key: 9, payload: out.len });
    }
    r
}

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    let local = ds.items;
    local.push(Row { key: 1, payload: 0 });
    let r1 = sh.freeze(ds);
    print("local alias: ", local.len, " ", ds.items.len);
    local.push(Row { key: 2, payload: 0 });
    let h = Holder { items: ds.items };
    let r2 = sh.freeze(ds);
    print("holder: ", h.items.len);
    h.items.push(Row { key: 5, payload: 0 });
    print("pushed through the holder: ", ds.items.len, " ", keys(ds.items));
    let r3 = through_caller(sh, ds, ds.items);
    print("caller's alias: ", ds.items.len, " ", ds.items[0].payload);
    print("frozen: ", keys(sh.view(r1)), " ", keys(sh.view(r2)), " ", keys(sh.view(r3)));
    // Two calls, so that the loop stays a function of its own at -O1.
    var loops = dynamic_stack<Row> {};
    var more = dynamic_stack<Row> {};
    let last = sh.view(alias_loop(sh, loops, 5));
    let other = sh.view(alias_loop(sh, more, 2));
    print("alias loop: ", last.len, " ", keys(last), " ", loops.items.len, " ",
          loops.items[0].payload, "; ", keys(other), " ", more.items.len);
}
