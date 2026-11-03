// error: the elements of i64&[2] are i64&, whose bits are an address
// A reference in a mapped file would be an address another process wrote
// (§11.4).
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("refs");
    print(view<(i64&)[2]>(sh, m, 0, 1).len);
}
