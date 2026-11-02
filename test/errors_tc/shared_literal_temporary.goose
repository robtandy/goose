// error: an attachment is made only by an owning declaration, local or global: let sh = shared {};
// Nor is `shared {}` a value of its own (§3.4, §11.4).
fn count(sh: shared&) -> i64 { 1 }

fn main() {
    print(count(shared {}));
}
