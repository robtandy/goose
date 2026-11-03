// Main, -1, cannot be watched (§11.2): the program ends with it.
struct Ended { id: i64 }
thread_fn worker() { thread_watch(-1, Ended { id: -1 }); }
fn main() {
    thread_wait(thread_spawn(worker));
    print("unreachable");
}
