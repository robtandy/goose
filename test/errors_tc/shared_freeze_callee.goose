// error: while e is still used
// Nor through a call: a callee that freezes a dynamic stack it is given
// shrinks its caller's array (§5.1, §11.4).
struct Row { key: i64 }

fn publish(sh: shared&, d: dynamic_stack<Row>&) -> resource<frozen<Row>> { sh.freeze(d) }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    ds.items.push(Row { key: 1 });
    let e .= ds.items[0];
    let r = publish(sh, ds);
    print(e.key);
}
