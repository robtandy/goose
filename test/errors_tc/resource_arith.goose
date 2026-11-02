// error: + cannot compute with resource<Buffer>: a handle has no arithmetic
// error: - cannot compute with resource<Buffer>: a handle has no arithmetic
// error: * cannot compute with resource<Buffer>
// error: % cannot compute with resource<Buffer>
// error: & cannot compute with resource<Buffer>
// error: ^ cannot compute with resource<Buffer>
// error: >> cannot compute with resource<Buffer>
// error: ~ cannot compute with resource<Buffer>
// error: += cannot update a resource<Buffer>: a handle has no arithmetic
// error: ++ cannot update a resource<Buffer>: a handle has no arithmetic
// No operator computes with a handle (§3.12), so no code makes a handle its
// kind's binding did not hand out.
struct Buffer {}
fn h() -> resource<Buffer> { default<resource<Buffer>>() }
fn add() { print(h() + h()); }
fn neg() { print(-h()); }
fn mul() { print(2 * h()); }
fn rem() { print(h() % 8); }
fn and() { print(h() & 0xff); }
fn xor() { print(h() ^ h()); }
fn shift() { print(h() >> 8); }
fn not() { print(~h()); }
fn update() { var r = h(); r += 1; }
fn step() { var r = h(); r++; }
fn main() { add(); neg(); mul(); rem(); and(); xor(); shift(); not(); update(); step(); }
