// checkfree loops over views of a mapped file (§7.14, §11.4). A view is a
// `const T[:]`, so a loop over one is a loop over a slice: plain loads, no
// check left. A view's own check, made once where it is made, is an abort
// of its own, not a bounds check, and a view's length is its count (§10.5),
// so an index below the count needs no check either.
import os;

let DIR = "gs_shared_checkfree";

struct Row { key: i64, payload: i64 }

checkfree fn sum(xs: const i64[:]) -> i64 {
    var s = 0;
    for x in xs { s += x; }
    s
}

checkfree fn dot(a: const i64[:], b: const i64[:]) -> i64 {
    assert(a.len == b.len);
    var s = 0;
    for i in a.len { s += a[i] * b[i]; }   // bce:elide
    s
}

// The view made inside: its count bounds the loop's index.
checkfree fn first_n(sh: shared&, m: resource<mapping>, n: i64) -> i64 {
    let xs = view<i64>(sh, m, 0, n);
    var s = 0;
    for i in n { s += xs[i]; }   // bce:elide
    s
}

// Rows and their keys, a column the same file holds in another shape: both
// lengths are counts, so 2 * i is below the second.
checkfree fn matches(sh: shared&, m: resource<mapping>, rows: i64) -> i64 {
    let rs = view<Row>(sh, m, 0, rows);
    let ks = view<i64>(sh, m, 0, 2 * rows);
    var hits = 0;
    for i in rs.len {
        if rs[i].key == ks[2 * i] { hits += 1; }   // bce:elide
    }
    hits
}

fn main() {
    make_dir(DIR);
    let p = str(DIR, "/col");
    var col: i64[>..] = [];
    for i in 1000 { col.push(i % 7 - 3); }
    write_file(p, bytes_of(col));
    let sh = shared {};
    let m, ok = sh.map_file(p);
    let xs = view<i64>(sh, m, 0, 1000);
    print(ok, " ", sum(xs), " ", dot(xs, xs), " ", first_n(sh, m, 10));
    print(matches(sh, m, 500));
    delete_file(p);
    delete_dir(DIR);
}
