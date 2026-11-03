// error: copying a value of type Entry, which contains self-relative references, is not supported
// Copying an element that holds links out of a view is rejected, as from
// any array: the copy's offsets would measure from the region (§3.9, §11.4).
struct Entry { key: i64, next: Entry&<u32>? }

fn main() {
    let sh = shared {};
    var ds = dynamic_stack<Entry> {};
    ds.items.push(Entry { key: 1, next: null });
    let t = sh.view(sh.freeze(ds));
    let e = t[0];
}
