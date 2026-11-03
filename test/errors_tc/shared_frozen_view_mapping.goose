// error: sh.view(r) views a frozen array, r a resource<frozen<T>>, not a resource<mapping>
// A mapped file's view says where in the file and how much (§11.4).
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    let v = sh.view(m);
}
