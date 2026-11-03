// error: event takes no type arguments
// `event`, the runtime's kind (§11.2), has no arguments.
fn f(e: resource<event<i64>>) {}
fn main() {}
