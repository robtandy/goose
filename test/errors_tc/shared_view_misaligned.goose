// error: view<i64> at byte offset 12, which is not a multiple of 8, the size of i64
// A constant offset that is not a multiple of the type's widest scalar is
// an error where it is written (§11.4); another is checked when the view
// is made.
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    print(view<i64>(sh, m, 12, 1).len);
}
