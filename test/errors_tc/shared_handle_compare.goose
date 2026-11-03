// error: == cannot compare resource<mapping>: a handle has no comparisons
// The runtime's handles are handles (§3.12): no comparison tells two
// mappings apart, which a bool kept beside them can.
fn main() {
    let sh = shared {};
    let a, ok = sh.map_file("a");
    let b, ok2 = sh.map_file("b");
    print(a == b);
}
