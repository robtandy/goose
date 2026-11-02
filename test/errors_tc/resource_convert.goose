// error: as cannot convert a resource<Buffer>: a handle converts to no other type
// error: as! cannot convert a resource<Buffer>: a handle converts to no other type
// error: as cannot make a resource<Buffer>: only its kind's binding makes a handle
// error: as! cannot make a resource<Buffer>: only its kind's binding makes a handle
// error: expected a value of type u64, got resource<Buffer>: a handle converts to no other type
// error: expected a value of type resource<Buffer>, got i64 constant: only its kind's binding makes a handle
// error: cannot pass u64 as resource<Buffer>: only its kind's binding makes a handle
// Neither cast converts a handle to or from an integer, and neither does
// anything implicit (§3.12).
struct Buffer {}
fn h() -> resource<Buffer> { default<resource<Buffer>>() }
fn take(r: resource<Buffer>) {}
fn to_int() { print(h() as u64); }
fn to_int_unchecked() { print(h() as! i64); }
fn from_int() { let bits: u64 = 1; print(bits as resource<Buffer>); }
fn from_int_unchecked() { print(-1 as! resource<Buffer>); }
fn implicit_to() { let bits: u64 = h(); print(bits); }
fn implicit_from() { let r: resource<Buffer> = 0; print(r); }
fn implicit_arg() { let bits: u64 = 1; take(bits); }
fn main() {
    to_int(); to_int_unchecked(); from_int(); from_int_unchecked();
    implicit_to(); implicit_from(); implicit_arg();
}
