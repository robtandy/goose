// error: cannot pass resource<Buffer> as u64: a handle converts to no other type
// error: bytes_of cannot write resource<Buffer>[1] out: resource<Buffer> is a handle, which only its kind's binding can read
// A handle hashes no more than it compares (§3.12): std's hash takes no
// handle, and no handle's bytes are there to hash.
import std;
struct Buffer {}
fn h() -> resource<Buffer> { default<resource<Buffer>>() }
fn direct() { print(hash(h())); }
fn bytes() { let a = [h()]; print(hash(bytes_of(a))); }
fn main() { direct(); bytes(); }
