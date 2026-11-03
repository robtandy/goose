// error: sh.freeze(ds) takes a dynamic stack, dynamic_stack<T>
// Only a dynamic stack is frozen; an ordinary array is frozen by appending
// it to one (§11.4).
fn main() {
    let sh = shared {};
    var a: i64[>..] = [1, 2];
    let r = sh.freeze(a);
}
