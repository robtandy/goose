// goose-threads
// A function checked for one par for and called again from another
// (docs/design/child_threads.md §4.6): what its check found holds for the
// second loop too. Here the generic run is handed bump, which a reduction
// of total makes, so each loop keeps per-chunk totals of its own and adds
// exactly n; the helper scale, which reads a global, is reused beside
// the parts of a local array, which no global is; and shift, whose calls
// all pass two arrays apart, each named exactly, keeps writing one while
// reading the other, whichever way around they come.
let FACTOR = 3;

fn run<F>() { F(); }

fn twice<F>() { F(); F(); }

fn scale(k: i64) -> i64 { return FACTOR * k; }

fn shift(dst: i64[:], src: const i64[:]) {
    par for k in dst.len { dst[k] = src[(k + 1) % dst.len] + 1; }
}

fn shift_on(x: i64[:], y: i64[:]) { shift(x, y); }

fn main() {
    var total = 0;
    fn bump() { total++; }
    let n = 100000;
    par for k in n { run(bump); }
    print(total);
    par for k in n { run(bump); }
    print(total);
    par for k in n { twice(bump); }
    print(total);
    var out: i64[8] = [0, 0, 0, 0, 0, 0, 0, 0];
    par for k in 8 { out[k] = scale(k); }
    par for k in 8 { out[k] += scale(1); }
    print(out);
    var a: i64[8] = [1, 2, 3, 4, 5, 6, 7, 8];
    var b: i64[8] = [10, 20, 30, 40, 50, 60, 70, 80];
    shift(a, b);
    shift(b, a);
    shift_on(a, b);
    shift_on(b, a);
    print(a, " ", b);
}
