// An id no thread_spawn has returned aborts qput_to (§11.2): one past the
// last issued, as here, or below -1. An ended worker's id is false instead.
struct Note { n: i64 }
thread_fn quick() {}
fn main() {
    let id = thread_spawn(quick);
    thread_wait(id);
    print(qput_to(-1, Note { n: 1 }), " ", qput_to(id, Note { n: 2 }));
    qput_to(id + 1, Note { n: 3 });
    print("unreachable");
}
