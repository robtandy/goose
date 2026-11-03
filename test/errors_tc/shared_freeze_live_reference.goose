// error: cannot freeze ds.items while e is still used
// A freeze is checked as ds.items.clear() is (§5.1, §11.4): no reference
// into the elements stays live across it.
struct Row { key: i64 }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    ds.items.push(Row { key: 1 });
    let e .= ds.items[0];
    let r = sh.freeze(ds);
    print(e.key);
}
