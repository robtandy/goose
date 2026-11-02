// Each kind's format overload renders its own handles (§3.7, §3.12), where
// two kinds differ only in what no C type has: a `const`, or an index type's
// array. So does each instance of a generic struct holding them.
struct Buffer {}
struct Both { a: resource<const Buffer>, b: resource<Buffer> }
struct Indexed { a: resource<u32 in xs>, b: resource<u32> }
struct Box<K> { r: resource<K> }

var xs: i64[>..] = [];

fn format(out: u8[>..]&, r: resource<const Buffer>) { out.append("<const Buffer>"); }
fn format(out: u8[>..]&, r: resource<Buffer>) { out.append("<Buffer>"); }
fn format(out: u8[>..]&, r: resource<u32 in xs>) { out.append("<u32 in xs>"); }
fn format(out: u8[>..]&, r: resource<u32>) { out.append("<u32>"); }

fn main() {
    print(Both { .. }, " ", Indexed { .. });
    let cb = Box<const Buffer> { r: default<resource<const Buffer>>() };
    let b = Box<Buffer> { r: default<resource<Buffer>>() };
    print(cb, " ", b, " ", str(b.r), " ", str(cb.r));
    let both: resource<Buffer>[2] = [b.r, b.r];
    print(both, " ", default<resource<const Buffer>>());
}
