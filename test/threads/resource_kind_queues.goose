// A queue carries one type (§11.2), and a handle's kind is part of its type
// (§3.12), whatever of it no C type has: a `const`, an index type's array, an
// `in pool` reference's pool. So two kinds that differ only there have a
// queue each, alone or inside two instances of a generic struct, and a poll
// of one never takes the other's message.
struct Buffer {}
struct Node { v: i64 }
struct Box<K> { r: resource<K> }

var xs:     i64[>..]  = [];
var pool_a: Node[>..] = [];
var pool_b: Node[>..] = [];

fn main() {
    qput(default<resource<const Buffer>>());
    let m1, other1 = qpoll<resource<Buffer>>();
    let n1, own1 = qpoll<resource<const Buffer>>();
    print("const: ", other1, " ", own1);

    qput(Box<const Buffer> { r: default<resource<const Buffer>>() });
    let m2, other2 = qpoll<Box<Buffer>>();
    let n2, own2 = qpoll<Box<const Buffer>>();
    print("in a generic struct: ", other2, " ", own2);

    qput(default<resource<u32 in xs>>());
    let m3, other3 = qpoll<resource<u32>>();
    let n3, own3 = qpoll<resource<u32 in xs>>();
    print("index type: ", other3, " ", own3);

    qput(default<resource<Node&<u32 in pool_a>>>());
    let m4, other4 = qpoll<resource<Node&<u32 in pool_b>>>();
    let n4, own4 = qpoll<resource<Node&<u32 in pool_a>>>();
    print("pool: ", other4, " ", own4);
}
