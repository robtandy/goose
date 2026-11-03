// error: event is the kind of an event's handle, written only as resource's argument: resource<event>
// error: event is the kind of an event's handle, written only as resource's argument: resource<event>
// `event` names the kind of an event's handle (§3.12), never a value.
fn local() { var k: event; }
fn param(k: event) {}
fn main() { local(); }
