// error: field name of Row is u8[:], a slice, whose address is one in the freezing thread's stacks
// Nor a slice (§11.4).
struct Row { key: i64, name: u8[:] }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Row> {};
    let r = sh.freeze(ds);
}
