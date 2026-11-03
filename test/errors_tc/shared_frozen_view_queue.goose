// error: queue elements must be flat (§11.2), not const Row[:]
// A view crosses no thread: its handle does (§11.2, §11.4).
struct Row { key: i64 }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    qput(sh.view(sh.freeze(ds)));
}
