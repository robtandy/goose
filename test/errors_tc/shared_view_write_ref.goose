// error: cannot write through this reference: non-writable provenance
// A reference to an element of a view is as read-only as the view (§9.5).
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    let v = view<i64>(sh, m, 0, 4);
    let r = &v[2];
    r = 1;
}
