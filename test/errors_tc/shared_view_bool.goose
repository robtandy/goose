// error: view<bool> of a mapped file takes plain data
// error: bool, of which only the bytes 0 and 1 are values
// A view's type is plain data, which every byte pattern is a value of
// (§11.4): bytes from outside are not checked one by one.
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("flags");
    print(view<bool>(sh, m, 0, 4).len);
}
