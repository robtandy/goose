// error: cannot assign through this path
// Nor through a link loaded from one, a `const T&` rooted at the
// attachment (§3.9, §11.4).
struct Entry { key: i64, next: Entry&<u32>? }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Entry> {};
    ds.items.push(Entry { key: 1, next: null });
    let e .= ds.items.push(Entry { key: 2, next: null });
    ds.items[0].next .= e;
    let t = sh.view(sh.freeze(ds));
    let n = t[0].next;
    assert(n);
    n.key = 3;
}
