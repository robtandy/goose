// error: root struct dynamic_stack<i64> can only be owned by a local or global variable; nested root owners are not supported
// A dynamic stack is a root owner (§3.4, §11.4), held by no struct.
struct Ctx { ds: dynamic_stack<i64>, n: i64 }

fn main() {}
