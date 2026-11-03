// error: a dynamic stack's literal takes no fields
// Its literal takes no fields: items starts empty (§11.4).
fn main() {
    var ds = dynamic_stack<i64> { items: [1] };
}
