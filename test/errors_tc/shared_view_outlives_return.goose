// error: returning a reference rooted in sh, which dies with this function
// A view is rooted at its attachment (§9.2, §11.4): one made through a local
// attachment cannot be returned, as the attachment ends with the function.
fn first(m: resource<mapping>) -> const i64[:] {
    let sh = shared {};
    view<i64>(sh, m, 0, 1)
}

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    print(first(m).len);
}
