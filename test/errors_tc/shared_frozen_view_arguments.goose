// error: view takes (sh, r), a frozen array's handle, or (sh, m, offset, count)
// A view takes two arguments or four (§11.4).
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    let v = view<i64>(sh, m, 0);
}
