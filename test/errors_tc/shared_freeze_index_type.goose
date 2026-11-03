// error: an index or bound type, which is proven against one thread's copy of its array
// Nor an index type, proven against one thread's copy of a global
// (§3.11, §11.4).
var words: i64[>..] = [];

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<u32 in words> {};
    let r = sh.freeze(ds);
}
