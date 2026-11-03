// error: cannot assign through this path
// A frozen array's view is a `const T[:]` (§9.5, §11.4): nothing writes
// what any thread may be reading.
struct Row { key: i64, payload: i64 }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    ds.items.push(Row { key: 1, payload: 2 });
    let rows = sh.view(sh.freeze(ds));
    rows[0].payload = 3;
}
