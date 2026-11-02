// error: view<i64> at byte offset 18446744073709551612, which is not a multiple of 8, the size of i64
// An unsigned constant above i64.max is checked as any other (§11.4).
let END = 18446744073709551612;

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    print(view<i64>(sh, m, END, 1).len);
}
