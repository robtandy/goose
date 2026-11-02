// error: root struct shared can only be owned by a local or global variable; nested root owners are not supported
// Nor held in a struct by value (§3.4).
struct Ctx { sh: shared, n: i64 }

fn main() {
    var c = Ctx { sh: shared {}, n: 1 };
}
