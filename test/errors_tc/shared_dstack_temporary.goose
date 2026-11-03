// error: a dynamic stack is made only by a local's owning declaration
// Nor is it made as a temporary (§3.4, §11.4).
fn take(d: dynamic_stack<i64>&) {}

fn main() {
    take(dynamic_stack<i64> {});
}
