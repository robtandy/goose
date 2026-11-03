// error: thread_fn parameters must be flat (§11.2), not dynamic_stack<i64>&
// Nor does one cross to a worker: until it is frozen it is as private as
// any array (§11.2, §11.4).
thread_fn worker(d: dynamic_stack<i64>&) {}

fn main() {
    var ds = dynamic_stack<i64> {};
    thread_wait(thread_spawn(worker, ds));
}
