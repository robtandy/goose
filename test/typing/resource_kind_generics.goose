// Two instances of a generic type whose handles' kinds differ only in a
// `const` are two types (§3.12), each with fields of its own types: by
// value, and through slices and references too. So both build, are passed
// to a generic function and are printed, in a struct and in an enum.
struct Buffer {}
struct Views<K> { items: resource<K>[:], first: resource<K>&, one: resource<K>, two: resource<K>[2] }
enum Maybe<K> { Nothing, Some { items: resource<K>[:] } }

fn count<K>(v: Views<K>&) -> i64 { v.items.len }

fn main() {
    let hs: resource<Buffer>[2]       = [default<resource<Buffer>>(), default<resource<Buffer>>()];
    let cs: resource<const Buffer>[2] = [default<resource<const Buffer>>(), default<resource<const Buffer>>()];
    let b = Views<Buffer> { items: hs, first: hs[0], one: hs[1], two: hs };
    let c = Views<const Buffer> { items: cs[..1], first: cs[0], one: cs[1], two: cs };
    print(count(b), " ", count(c));
    print(b);
    print(c);
    let mb: Maybe<Buffer>       = Maybe<Buffer>.Some { items: hs };
    let mc: Maybe<const Buffer> = Maybe<const Buffer>.Some { items: cs };
    print(mb, " ", mc);
}
