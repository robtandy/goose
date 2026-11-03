// A closed event is closed for good (§11.2): a second close aborts.
struct Io { n: i64 }
fn main() {
    let e = event(Io { n: 1 });
    event_close(e);
    print("closed once");
    event_close(e);
}
