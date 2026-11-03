// error: u32 in nodes, an index or bound type, which is checked against one thread's array
// Nor an index type, whose values are proven against an array of the
// program's own (§3.11, §11.4).
var nodes: i64[>..] = [];

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("ids");
    print(view<u32 in nodes>(sh, m, 0, 4).len);
}
