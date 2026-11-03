// error: calls into its recursive cycle while non-fixed-size local ds
// Holding a resizable, it is never live across a call into a recursive
// cycle (§7.8, §11.4).
recursive fn walk(n: i64) -> i64 {
    var ds = dynamic_stack<i64> {};
    ds.items.push(n);
    if n == 0 { return 0; }
    walk(n - 1) + ds.items.len
}

fn main() { print(walk(3)); }
