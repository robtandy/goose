// A queue carries one type (§11.2), which a type argument no field uses
// tells apart too: P<K<i64>> and P<K<f64>>, whose K is never instantiated,
// have a queue each.
struct K<T> {}
struct P<T> { n: i64 }

fn main() {
    qput(P<K<i64>> { n: 1 });
    let m1, other = qpoll<P<K<f64>>>();
    let m2, own = qpoll<P<K<i64>>>();
    print(other, " ", own, " ", m2.n);
}
