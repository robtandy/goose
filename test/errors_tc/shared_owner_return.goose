// error: root struct shared can only be owned by a local or global variable; return a reference instead
// Nor returned by value (§3.4).
fn make() -> shared {
    let sh = shared {};
    sh
}

fn main() {}
