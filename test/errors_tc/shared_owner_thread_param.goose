// error: thread_fn parameters must be flat (§11.2), not shared&
// An attachment stays in its thread: a worker attaches the arena's handle
// itself (§11.2, §11.4).
thread_fn w(sh: shared&) {}

fn main() {
    let sh = shared {};
    thread_spawn(w, sh);
}
