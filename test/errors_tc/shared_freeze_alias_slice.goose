// error: cannot freeze ds.items while s is still used
// An alias's slice blocks a freeze as the array's own does (§5.1, §11.4).
fn main() {
    let sh = shared {};
    var ds = dynamic_stack<i64> {};
    let a = ds.items;
    a.push(1);
    let s = a[..];
    let r = sh.freeze(ds);
    print(s.len);
}
