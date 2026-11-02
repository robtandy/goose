// A function returning u8[] whose value is a builtin's fixed-size result,
// the slice embed_file or bytes_of gives or the fixed array default makes,
// received into a resizable array: the caller builds the run from that
// value, as from any slice or fixed array, since the builtin builds none.
// deep is recursive, so that -O2 does not inline it either.
fn table() -> u8[] { embed_file("embed_file.txt") }

fn raw(xs: i64[>..]&) -> u8[] { bytes_of(xs) }

fn zeros() -> u8[] { default<u8[4]>() }

recursive fn deep(n: i64) -> u8[] {
    if n > 0 { return deep(n - 1); }
    embed_file("embed_file.txt")
}

fn main() {
    var a: u8[>..] = table();
    a.push('!');
    print(a.len, " ", a[0], " ", a[a.len - 1]);
    var xs: i64[>..] = [7];
    var b:  u8[>..]  = raw(xs);
    var sum = 0;
    for x in b { sum += x; }
    print(b.len, " ", sum);
    var z: u8[>..] = zeros();
    z.push(9);
    print(z.len, " ", z[3], " ", z[4]);
    var d: u8[>..] = deep(3);
    print(d.len == table().len, " ", d[0] == a[0]);
}
