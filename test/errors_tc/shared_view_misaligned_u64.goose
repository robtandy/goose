// error: view<i64> at byte offset 12, which is not a multiple of 8, the size of i64
// A constant offset converted to another integer type is a constant offset
// still (§11.4): a conversion keeps the low bits an alignment reads, or
// aborts in a debug build, so the view could never be made.
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    print(view<i64>(sh, m, 12 as u64, 1).len);
}
