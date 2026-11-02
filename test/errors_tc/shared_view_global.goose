// error: storing a reference rooted at sh, which does not outlive the destination
// A view made through a local attachment does not go into a global, which
// outlives every local (§9.2, §11.4); a global attachment's views may.
var kept: (const i64[:])[>..];

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    kept.push(view<i64>(sh, m, 0, 4));
}
