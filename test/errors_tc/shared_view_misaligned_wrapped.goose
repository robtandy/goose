// error: view<i32> at byte offset 2, which is not a multiple of 4, the size of i32
// The offset a conversion makes of a constant is the one checked (§11.4):
// as! keeps the low 32 bits of 2^32 + 2.
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i32");
    print(view<i32>(sh, m, 4294967298 as! u32, 1).len);
}
