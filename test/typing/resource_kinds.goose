// The kind of a resource<U> (§3.12): any type names one, and two types name
// two kinds. A binding declares a type for its kind, which is never made,
// and its functions, in its namespace, are its handles' methods (§11.1).
// A generic function or struct takes a kind as it takes any type, and a
// type may name itself as a kind, since a handle holds none of its kind's
// values. A type of the program's own named resource keeps its meaning,
// where ::resource names the handle. A format overload gives a kind's
// handles a text of their own (§3.7), and an export passes a handle to C
// as the uint64_t it is (§7.11).
import kinds.gpu;

struct Texture<T> {}
struct Node { id: i64, self_handle: resource<Node> }
struct Labeled {}
type Buf = resource<gpu::Buffer>;

// Generic over the kind.
fn same<K>(r: resource<K>) -> resource<K> { r }
struct Shelf<K> { items: resource<K>[>..] }
fn count<K>(s: Shelf<K>&) -> i64 { s.items.len }

fn format(out: u8[>..]&, r: resource<Labeled>) { out.append("<a Labeled handle>"); }

export "resource_kinds_pass" fn pass(r: resource<Texture<f32>>) -> resource<Texture<f32>> { r }
extern fn pass_from_c(r: resource<Texture<f32>>) -> resource<Texture<f32>> = "resource_kinds_pass";

fn main() {
    // A binding's namespaced kind: its handles' methods are its functions.
    let b: Buf = gpu::none();
    print(b.describe(), ": ", b, " ", same(b));
    let r = gpu::resource { name: "local" };
    print(gpu::named(r), " ", r);

    // Kinds of every sort, and a generic struct over them.
    let t = default<resource<Texture<f32>>>();
    let tu = default<resource<Texture<u8>>>();
    let i = default<resource<i64>>();
    let n = Node { id: 1, self_handle: default<resource<Node>>() };
    print(same(t), " ", tu, " ", i, " ", n);
    var shelf = Shelf<Texture<f32>> { items: [] };
    shelf.items.push(t);
    shelf.items.push(pass(t));
    shelf.items.push(pass_from_c(t));
    print(count(shelf), " ", shelf.items);

    // A kind's own text.
    let l = default<resource<Labeled>>();
    let ls: resource<Labeled>[2] = [l, l];
    print(l, " ", ls, " ", str(l));
}
