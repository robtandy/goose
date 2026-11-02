// A binding's kind declared in a namespace of its own, for
// resource_kinds.goose: its functions are its handles' methods (§11.1), and
// a type of its own named resource keeps its meaning there, where
// ::resource names the handle (§3.12).
namespace gpu;

struct Buffer {}
struct resource { name: u8[..8] }

fn describe(b: ::resource<Buffer>) -> const u8[:] { "a gpu::Buffer handle" }
fn none() -> ::resource<Buffer> { default<::resource<Buffer>>() }
fn named(r: resource) -> u8[..8] { r.name }
