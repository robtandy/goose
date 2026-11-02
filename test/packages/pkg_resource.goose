// A binding's own kinds of resource<U> (spec §3.12): the C beside this
// program (pkg_resource_impl.c, named by the sidecar pkg_resource.build)
// hands out handles to native byte buffers and to a stand-in for a GPU's
// buffers, the examples of docs/design/owning_dynamic_data.md's option C,
// and checks each handle it is handed back. The tags are this program's own
// types, which name the two kinds. C sees each handle as the uint64_t it
// is, and Goose stores, copies and passes it, and nothing else: a handle
// owns nothing, so copying one changes nothing, and releasing what it names
// leaves every copy stale, by the binding's own rules.
struct ByteBuffer {}
struct GpuBuffer {}

extern fn bytes_new(size: i64) -> resource<ByteBuffer>;
extern fn bytes_size(b: resource<ByteBuffer>) -> i64;
extern fn bytes_write(b: resource<ByteBuffer>, at: i64, data: const u8[:]) -> bool;
extern fn bytes_read(b: resource<ByteBuffer>, at: i64, n: i64, out: u8[>..]&) -> bool;
extern fn bytes_release(b: resource<ByteBuffer>) -> bool;
extern fn bytes_new_into(size: i64, out: resource<ByteBuffer>&) -> bool;
extern fn bytes_total(bs: const resource<ByteBuffer>[:]) -> i64;
extern fn bytes_is_zero(b: resource<ByteBuffer>) -> bool;
extern fn bytes_slot(b: resource<ByteBuffer>) -> i64;

extern fn gpu_create(n: i64) -> resource<GpuBuffer>;
extern fn gpu_upload(g: resource<GpuBuffer>, data: const f32[:]) -> bool;
extern fn gpu_draw(g: resource<GpuBuffer>) -> f64;
extern fn gpu_release(g: resource<GpuBuffer>) -> bool;
// The GPU's draw declared at the byte buffers' kind: Goose passes it only
// those, and the binding refuses them, since it made them for another kind.
extern fn gpu_draw_bytes(b: resource<ByteBuffer>) -> f64 = "gpu_draw";

// A struct holding a handle crosses by value, as its packed C form.
struct Named { tag: i32, buf: resource<ByteBuffer> }
extern fn named_size(n: Named) -> i64;

var kept: resource<ByteBuffer>;

fn text(b: resource<ByteBuffer>, at: i64, n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    if !bytes_read(b, at, n, out) { out.append("(no read)"); }
    return out;
}

fn main() {
    // Made by C, and handed back to it.
    let a = bytes_new(8);
    print("a: size ", bytes_size(a), ", slot ", bytes_slot(a), ", zero ", bytes_is_zero(a));
    print("write ", bytes_write(a, 2, "hi"), ", past the end ", bytes_write(a, 7, "ab"));
    print("read \"", text(a, 2, 2), "\", past the end \"", text(a, 6, 4), "\"");

    // The zero handle names nothing, and C sees it as 0.
    let none = default<resource<ByteBuffer>>();
    print("zero handle: zero ", bytes_is_zero(none), ", size ", bytes_size(none),
          ", kept ", bytes_is_zero(kept));

    // In Goose storage: a global, a field, array elements, a slice of them,
    // and one C writes through a reference.
    kept = bytes_new(16);
    var c = default<resource<ByteBuffer>>();
    print("into ", bytes_new_into(32, c), ", size ", bytes_size(c));
    var all: resource<ByteBuffer>[>..] = [];
    all.push(a);
    all.push(kept);
    all.push(c);
    print("total ", bytes_total(all), ", of two ", bytes_total(all[1..]));
    let n = Named { tag: 7, buf: all[1] };
    print("named ", named_size(n), " ", n);

    // A copy names the same buffer. Releasing it stales every copy, and a
    // buffer made after it, in the slot it left, is not named by them.
    let alias = a;
    print("release ", bytes_release(alias), ", again ", bytes_release(a), ", size ",
          bytes_size(a), ", total ", bytes_total(all));
    let d = bytes_new(4);
    print("d: slot ", bytes_slot(d), ", size ", bytes_size(d), "; a: size ", bytes_size(a));

    // The GPU's kind: made, uploaded, drawn and released.
    let g = gpu_create(3);
    let vs: f32[3] = [1.5, 2.0, 0.25];
    print("gpu: upload ", gpu_upload(g, vs), ", draw ", gpu_draw(g), ", as bytes ",
          gpu_draw_bytes(kept));
    print(g, " ", a, " ", all);
    print("gpu release ", gpu_release(g), ", draw ", gpu_draw(g));
    print("release ", bytes_release(kept), " ", bytes_release(c), " ", bytes_release(d));
}
