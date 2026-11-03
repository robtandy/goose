// Only an event's own thread closes it (§11.2): another thread holding the
// handle may pass it on, but not close it.
struct Io { n: i64 }
struct Handle { e: resource<event> }
thread_fn closer() {
    let h = qget<Handle>();
    event_close(h.e);
}
fn main() {
    let e = event(Io { n: 1 });
    qput(Handle { e: e });
    thread_wait(thread_spawn(closer));
    print("unreachable");
}
