// error: an attachment is made only by an owning declaration, local or global: let sh = attach(h);
// An attachment is a root owner (§3.4, §11.4), which only a declaration
// holds: attach is no value of its own.
fn count(sh: shared&) -> i64 { 1 }

fn main() {
    let sh = shared {};
    print(count(attach(sh.handle)));
}
