// error: field next of Node is Node&<u32 in pool>?, measured from pool, a global of which each thread has its own copy
// Nor an `in pool` link, measured from a global that each thread copies
// (§3.9, §11.2, §11.4).
struct Node { key: i64, next: Node&<u32 in pool>? }
var pool: Node[>..] = [];

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Node> {};
    let r = sh.freeze(ds);
}
