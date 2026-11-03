// error: field owner of Row is i64&, a reference, whose address is one in the freezing thread's stacks
// A frozen array is read in place by any thread, so its elements hold no
// address in the stacks of the thread that made them (§11.4).
struct Row { key: i64, owner: i64& }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    let r = sh.freeze(ds);
}
