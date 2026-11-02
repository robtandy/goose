// error: resource takes one type argument, the kind of thing a handle names: resource<U>
// error: resource takes one type argument, the kind of thing a handle names: resource<U>
// error: resource<U> has no variable mode
// A handle names one kind (§3.12), and is no ADT.
struct Buffer {}
fn none(r: resource) {}
fn two(r: resource<Buffer, Buffer>) {}
fn varmode(r: resource<Buffer>..) {}
fn main() {}
