// resource<U> is found only where no declaration of the program has the
// name (§3.12): a program declaring a type named resource keeps it, generic
// arguments and comparisons included, and has no handles.
struct resource<T> { v: T }

fn main() {
    let r = resource<i64> { v: 3 };
    print(r, " ", r == r, " ", r.v + 1);
}
