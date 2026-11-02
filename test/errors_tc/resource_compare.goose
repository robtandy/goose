// error: == cannot compare resource<Buffer>: a handle has no comparisons
// error: != cannot compare resource<Buffer>: a handle has no comparisons
// error: < cannot compare resource<Buffer>
// error: <= cannot compare resource<Buffer>
// error: > cannot compare resource<Buffer>
// error: >= cannot compare resource<Buffer>
// error: == cannot compare Slot, which holds a resource<Buffer>
// error: == cannot compare resource<Buffer>[2], which holds a resource<Buffer>
// error: != cannot compare resource<Buffer>[:], which holds a resource<Buffer>
// error: == cannot compare Held, which holds a resource<Buffer>
// A handle has no comparisons (§3.12), not even with the zero handle, and a
// value holding one has no ==, which would compare it.
struct Buffer {}
struct Slot { id: i64, b: resource<Buffer> }
enum Held { Empty, One { b: resource<Buffer> } }
fn h() -> resource<Buffer> { default<resource<Buffer>>() }
fn eq() { print(h() == default<resource<Buffer>>()); }
fn ne() { let r = h(); print(r != r); }
fn lt() { print(h() < h()); }
fn le() { print(h() <= h()); }
fn gt() { print(h() > h()); }
fn ge() { print(h() >= h()); }
fn field() { let s = Slot { id: 1, b: h() }; print(s == s); }
fn elements() { let a: resource<Buffer>[2] = [h(), h()]; print(a == a); }
fn viewed() { var a: resource<Buffer>[>..] = []; print(a[..] != a[..]); }
fn payload() { let e: Held = Held.One { b: h() }; print(e == e); }
fn main() { eq(); ne(); lt(); le(); gt(); ge(); field(); elements(); viewed(); payload(); }
