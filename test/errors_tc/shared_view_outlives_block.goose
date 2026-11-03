// error: storing a reference rooted at sh, which does not outlive the destination
// A view kept in a variable that outlives the attachment it was made
// through: the attachment's block ends first (§9.2, §11.4).
fn main() {
    let outer = shared {};
    let m, ok = outer.map_file("col.i64");
    var v = view<i64>(outer, m, 0, 0);
    {
        let sh = attach(outer.handle);
        v = view<i64>(sh, m, 0, 1);
    }
    print(v.len);
}
