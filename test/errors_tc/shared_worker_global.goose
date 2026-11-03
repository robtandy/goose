// error: thread programs cannot copy root global gsh
// A worker cannot use main's global attachment (§11.2, §11.4): it attaches
// the handle main gives it.
let gsh = shared {};

thread_fn w() {
    let m, ok = gsh.map_file("col.i64");
}

fn main() {
    thread_spawn(w);
}
