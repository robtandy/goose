// goose-threads
// What a par for's body builds of its own it writes through, in functions
// it calls too (docs/design/child_threads.md §4.3): holders and arrays of
// references to its own variables, copies of them, and references to those.
// And a root struct's components are storage apart (§3.9): the iterations
// own the elements of one while the body reads another, and the length of
// the one they own.
struct H { r: i64& }

fn bump(h: H) { h.r += 1; }

fn bumpref(h: H&) { h.r += 2; }

fn bumpall(rs: i64&[2]) {
    rs[0] += 3;
    rs[1] += 4;
}

root struct S { first: i64[>..], second: i64[>..] }

fn main() {
    var out: i64[8] = [0, 0, 0, 0, 0, 0, 0, 0];
    par for k in 8 {
        var a = k;
        var b = 10 * k;
        let h = H { r: a };
        bump(h);
        var c = h;
        c.r += 1;
        bumpref(c);
        let rs: i64&[2] = [a, b];
        bumpall(rs);
        var copy = rs;
        copy[1] += 1;
        out[k] = a + b;
    }
    print(out);
    var s = S { first: [1, 2, 3, 4, 5, 6, 7, 8], second: [5, 6] };
    par for &x in s.first { x = x + s.second[0] + s.first.len; }
    print(s.first);
}
