// error: extern fn poke: parameter xs of type i64[:] takes a writable value; a read-only one needs the parameter declared const
// Nor through C: an extern fn takes a view only where its parameter is
// declared const (§7.10, §9.5), and the mapping is read-only besides.
extern fn poke(xs: i64[:]) = "poke";

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    poke(view<i64>(sh, m, 0, 4));
}
