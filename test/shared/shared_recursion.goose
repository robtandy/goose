// An attachment lasts until its scope exits (§11.4), in a recursive function
// too: a self-call in tail position runs while the caller's attachment still
// holds its arena, so the callee attaches that arena by the handle the
// caller saved, optimized, where the self-call could have become a loop, as
// not. The test is written so that it is no base case to copy to the call.
var saved: resource<shared>;

recursive fn walk(n: i64) -> i64 {
    let sh = shared {};
    if n + 1 > 1 {
        saved = sh.handle;
        return walk(n - 1);
    }
    let parent = attach(saved);
    n
}

// The accumulating form, each level adding its own.
recursive fn total(n: i64) -> i64 {
    let sh = shared {};
    if n + 1 > 1 {
        saved = sh.handle;
        return n + total(n - 1);
    }
    let parent = attach(saved);
    0
}

fn main() {
    print(walk(2));    // 0
    print(total(4));   // 10
}
