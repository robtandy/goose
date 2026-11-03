// error: dynamic_stack<i64> is a dynamic stack, which no handle names
// A frozen array's handle is a resource<frozen<T>> (§3.12, §11.4).
fn main() {
    var h: resource<dynamic_stack<i64>>;
}
