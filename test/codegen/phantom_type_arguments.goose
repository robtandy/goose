// A type argument that no field uses is never instantiated (`K<i64>` in
// `P<K<i64>>`, as P's one field uses no T), and the C types of what holds it
// are named and laid out without it, wherever such a type is written again.
struct K<T> {}
struct P<T> { n: i64 }
struct Q<A, B> { a: A }

fn total(p: P<K<i64>>, q: P<K<i64>>) -> i64 { p.n + q.n }

fn main() {
    let a = P<K<i64>> { n: 1 };
    let b: P<K<i64>> = P<K<i64>> { n: 2 };
    let c = P<K<const i64>> { n: 3 };
    let d = Q<i64, K<f64>> { a: 4 };
    var ps: P<K<i64>>[>..] = [];
    ps.push(a);
    ps.push(b);
    print(total(a, b), " ", c.n, " ", d.a, " ", ps, " ", c);
}
