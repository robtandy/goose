// error: cannot assign through this path
// A view is a `const T[:]` (§9.5, §11.4): nothing writes through it.
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    let v = view<i64>(sh, m, 0, 4);
    v[0] = 7;
}
