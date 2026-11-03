// error: cannot assign through this path
// error: in fn zero
// Nor does a function given one, whose parameter takes its constness
// (§9.5, §11.4): the write is an error at this instantiation.
struct Row { key: i64 }

fn zero(rows: Row[:]) { for &r in rows { r.key = 0; } }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    ds.items.push(Row { key: 1 });
    zero(sh.view(sh.freeze(ds)));
}
