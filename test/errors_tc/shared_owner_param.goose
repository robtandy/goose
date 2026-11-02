// error: root struct shared can only be owned by a local or global variable; pass it by reference instead
// An attachment is passed by reference, as every root owner is (§3.4).
fn count(sh: shared) -> i64 { 1 }

fn main() {
    let sh = shared {};
    print(count(sh));
}
