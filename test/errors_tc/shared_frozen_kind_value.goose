// error: frozen<i64> is the kind of a frozen array's handle, written only as resource's argument
// frozen<T> names a kind only (§3.12, §11.4).
fn main() {
    var x: frozen<i64>;
}
