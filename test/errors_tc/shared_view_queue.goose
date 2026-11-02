// error: queue elements must be flat (§11.2), not Msg
// A view does not cross threads (§11.2, §11.4): a message holding one is
// not flat. The handles cross, and the receiver views them itself.
struct Msg { xs: const i64[:] }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    qput(Msg { xs: view<i64>(sh, m, 0, 4) });
}
