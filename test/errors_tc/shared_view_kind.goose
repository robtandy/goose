// error: expected a value of type resource<mapping>, got resource<shared>
// A view takes a mapping's handle: an arena's is of another kind (§3.12).
fn main() {
    let sh = shared {};
    print(view<i64>(sh, sh.handle, 0, 1).len);
}
