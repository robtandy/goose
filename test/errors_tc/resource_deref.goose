// error: no field access on a value of type resource<Buffer>: a handle is never dereferenced
// error: cannot index a value of type resource<Buffer>: a handle is never dereferenced
// error: cannot slice a value of type resource<Buffer>: a handle is never dereferenced
// error: cannot iterate a value of type resource<Buffer>: a handle is never dereferenced
// error: expected a value of type Buffer, got resource<Buffer>: a handle converts to no other type
// error: cannot pass resource<Buffer> as Buffer&: a handle is never dereferenced
// error: cannot construct a value of type resource<Buffer> with a literal: only its kind's binding makes a handle
// A handle names something code does not reach into (§3.12): not its
// fields, elements or bytes, nor a value of its kind, which it holds none
// of, and no literal makes one.
struct Buffer { size: i64 }
fn h() -> resource<Buffer> { default<resource<Buffer>>() }
fn size_of(b: Buffer&) -> i64 { b.size }
fn field() { print(h().size); }
fn index() { let r = h(); print(r[0]); }
fn slice() { let r = h(); print(r[0..1]); }
fn iterate() { for x in h() { print(x); } }
fn as_kind() { let b: Buffer = h(); print(b); }
fn as_kind_ref() { let r = h(); print(size_of(r)); }
fn literal() { print(resource<Buffer> {}); }
fn main() { field(); index(); slice(); iterate(); as_kind(); as_kind_ref(); literal(); }
