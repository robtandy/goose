// error: cannot assign through this path
// error: in fn zero
// Nor does a function given one, whose parameter takes its constness
// (§9.5): the write is an error at this instantiation.
fn zero(xs: i64[:]) { for i in xs.len { xs[i] = 0; } }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    zero(view<i64>(sh, m, 0, 4));
}
