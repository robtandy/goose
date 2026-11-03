// error: view<i64>(sh, r) of a frozen array of Row
// view<T>(sh, r) names r's own element type (§11.4).
struct Row { key: i64 }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    let r = sh.freeze(ds);
    let v = view<i64>(sh, r);
}
