// error: extern fn make_event cannot return resource<event>: C takes the runtime's handles, but only the runtime makes one
// error: extern fn make_io cannot return Io: it holds a resource<event>, and C takes the runtime's handles
// error: extern fn fill: parameter e of type resource<event>& lets C write a resource<event>, which only the runtime makes
// error: extern fn fill_all: parameter es of type resource<event>[:] lets C write a resource<event>
// error: export fn take_event: parameter e of type resource<event> would take a resource<event> from C
// An event's handle is one of the runtime's (§3.12, §7.10): C takes it, by
// value or read-only, but never makes one, so no extern fn returns one, by
// itself or in a value, or writes one through a parameter, and no exported
// function takes one from C.
struct Io { id: i64, done: resource<event> }
extern fn make_event() -> resource<event>;
extern fn make_io() -> Io;
extern fn fill(e: resource<event>&);
extern fn fill_all(es: resource<event>[:]);
extern fn keep(e: resource<event>, all: const resource<event>[:], io: const Io&) -> i64;
export fn take_event(e: resource<event>) -> i64 { 0 }
fn main() {}
