// error: expected a value of type resource<Texture>, got resource<Buffer>: a handle of one kind is never one of another
// error: cannot pass resource<Buffer> as resource<Texture>: a handle of one kind is never one of another
// error: expected a value of type resource<Texture>, got resource<Buffer>
// error: expected a value of type resource<Image<f32>>, got resource<Image<u8>>: a handle of one kind is never one of another
// error: expected a value of type resource<Buffer>, got resource<const Buffer>: a handle of one kind is never one of another
// A kind is part of a handle's type (§3.12): no handle of one kind is ever
// taken for one of another, generic kinds included, nor where they differ
// only in a `const`.
struct Buffer {}
struct Texture {}
struct Image<T> {}
fn buffer() -> resource<Buffer> { default<resource<Buffer>>() }
fn draw(t: resource<Texture>) {}
fn stored() { let t: resource<Texture> = buffer(); print(t); }
fn passed() { draw(buffer()); }
fn returned() -> resource<Texture> { return buffer(); }
fn element() { var is: resource<Image<f32>>[>..] = []; is.push(default<resource<Image<u8>>>()); }
fn qualified() { let b: resource<Buffer> = default<resource<const Buffer>>(); print(b); }
fn main() { stored(); passed(); returned(); element(); qualified(); }
