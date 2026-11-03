// error: a dynamic stack is a local's, whose scope hands its slot back, not a global's
// A dynamic stack is made by a local's owning declaration (§11.4).
var ds = dynamic_stack<i64> {};

fn main() {}
