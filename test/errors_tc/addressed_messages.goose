// error: queue elements must be flat (§11.2), not i64[:]
// error: queue elements must be flat (§11.2), not const u8[:]
// error: queue elements must be flat (§11.2), not Held
// A message to one thread, a watch's and an event's are flat, as a queue's
// are (§11.2).
fn to(v: i64[:]) { qput_to(0, v); }
fn watch(s: const u8[:]) { thread_watch(0, s); }
struct Held { s: i64[:] }
fn ev(v: i64[:]) { let e = event(Held { s: v }); }
fn main() {
    var a: i64[>..] = [1];
    to(a);
    watch("x");
    ev(a);
}
