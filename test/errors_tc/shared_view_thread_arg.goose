// error: thread_fn parameters must be flat (§11.2), not const i64[:]
// Nor as a worker's argument (§11.2, §11.4).
thread_fn w(xs: const i64[:]) { print(xs.len); }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    thread_spawn(w, view<i64>(sh, m, 0, 4));
}
