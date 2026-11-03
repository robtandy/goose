// error: storing a reference rooted at sh, which does not outlive the destination
// A view used after its attachment's block, which may have released its
// arena: statically known, the use is a compile error (§9.2, §11.4).
struct Row { key: i64 }

fn main() {
    let outer = shared {};
    var ds = dynamic_stack<Row> {};
    ds.items.push(Row { key: 1 });
    let r = outer.freeze(ds);
    var v = outer.view(r);
    {
        let sh = attach(outer.handle);
        v = sh.view(r);
    }
    print(v.len);
}
