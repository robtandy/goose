// error: storing a reference rooted at sh, which does not outlive the destination
// Nor goes into a global, which outlives every local (§9.2, §11.4).
struct Row { key: i64 }
var kept: (const Row[:])[>..];

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    kept.push(sh.view(sh.freeze(ds)));
}
