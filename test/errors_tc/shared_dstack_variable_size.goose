// error: dynamic_stack<T> holds fixed-size elements (§11.4), and u8[] is not fixed-size
// Its elements are fixed-size, which a freeze hands on as they lie (§11.4).
fn main() {
    var ds = dynamic_stack<u8[]> {};
}
