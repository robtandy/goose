// A worker cannot watch itself (§11.2): it is not ended until it returns.
struct Ended { id: i64 }
thread_fn worker() { thread_watch(thread_id(), Ended { id: thread_id() }); }
fn main() {
    thread_wait(thread_spawn(worker));
    print("unreachable");
}
