// error: storing a read-only slice of type const i64[:] in a slot of type i64[:]
// A view goes only into a slot declared const (§9.5, §11.4).
struct Col { xs: i64[:] }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    let c = Col { xs: view<i64>(sh, m, 0, 4) };
    print(c.xs.len);
}
