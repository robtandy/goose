// error: == cannot compare resource<event>: a handle has no comparisons
// error: expected a value of type resource<event>, got i64 constant: only its kind's binding makes a handle
// error: as cannot make a resource<event>: only its kind's binding makes a handle
// An event's handle is a resource<event> (§3.12, §11.2): never compared,
// made from an integer or taken by event_close as anything else.
struct Io { n: i64 }
fn compare() { print(event(Io { n: 1 }) == event(Io { n: 2 })); }
fn closeint() { event_close(5); }
fn forge() { let e = 5 as resource<event>; }
fn main() { compare(); closeint(); forge(); }
