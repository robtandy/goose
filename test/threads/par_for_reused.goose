// goose-threads
// A function checked for one par for and called again from another
// (docs/design/child_threads.md §4.6): what its check found holds for the
// second loop too. Here the generic run is handed bump, which a reduction
// of total makes, so each loop keeps per-chunk totals of its own and adds
// exactly n; and the helper scale, which reads a global, is reused beside
// the parts of a local array, which no global is.
let FACTOR = 3;

fn run<F>() { F(); }

fn twice<F>() { F(); F(); }

fn scale(k: i64) -> i64 { return FACTOR * k; }

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
}
