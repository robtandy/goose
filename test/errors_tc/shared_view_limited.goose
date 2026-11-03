// error: i64[..4], a limited array, whose length only goes up to its capacity
// Nor a limited array, whose length must not exceed its capacity (§11.4).
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("rows");
    print(view<i64[..4]>(sh, m, 0, 1).len);
}
