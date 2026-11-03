// error: view<T>(sh, m, offset, count) needs exactly one explicit type argument
// A view names the type it views (§11.4).
fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    print(sh.view(m, 0, 1).len);
}
