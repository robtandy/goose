// error: and ds.items is a i64[>..]
// freeze takes the dynamic stack, not its array (§11.4).
fn main() {
    let sh = shared {};
    var ds = dynamic_stack<i64> {};
    let r = sh.freeze(ds.items);
}
