// error: cannot freeze ds.items while h is still used
// Nor one in a holder (§5.1, §11.4).
struct Row { key: i64 }
struct Holder { row: Row& }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    ds.items.push(Row { key: 1 });
    let h = Holder { row: ds.items[0] };
    let r = sh.freeze(ds);
    print(h.row.key);
}
