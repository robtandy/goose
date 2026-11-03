// The zero handle names no event (§3.12, §11.2), so closing it aborts.
struct Io { n: i64 }
fn main() {
    let e = event(Io { n: 1 });
    event_close(e);
    let none = default<resource<event>>();
    print(none);
    event_close(none);
}
