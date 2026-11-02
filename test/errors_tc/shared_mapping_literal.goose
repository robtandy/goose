// error: mapping is the kind of a mapped file's handle, which no value has
// Nor does a literal make one (§11.4).
fn main() {
    let m = mapping {};
}
