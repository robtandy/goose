// error: to_bytes cannot write resource<Buffer>[2] out: resource<Buffer> is a handle, which only its kind's binding can read, in this process
// error: to_bytes cannot write Slot[1] out: resource<Buffer> is a handle
// error: bytes_of cannot write Slot[1] out: resource<Buffer> is a handle
// error: from_bytes<resource<Buffer>[>..]> has no verifier: resource<Buffer> is a handle
// error: from_bytes<Slot[]> has no verifier: resource<Buffer> is a handle
// A handle means something only to its binding, in one process, so it has
// no image (§3.12): neither a handle nor a value holding one is written out
// or read back in.
struct Buffer {}
struct Slot { id: i64, b: resource<Buffer> }
fn h() -> resource<Buffer> { default<resource<Buffer>>() }
fn written() { let a = [h(), h()]; print(a.to_bytes()); }
fn appended() { let a = [Slot { id: 1, b: h() }]; var out: u8[>..] = []; a.to_bytes(out); }
fn viewed() { let a = [Slot { id: 1, b: h() }]; print(bytes_of(a)); }
fn read() { let bs, ok = from_bytes<resource<Buffer>[>..]>(""); print(ok); }
fn read_holders() { let bs, ok = from_bytes<Slot[]>(""); print(ok); }
fn main() { written(); appended(); viewed(); read(); read_holders(); }
