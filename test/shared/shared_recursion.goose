// An attachment lasts until its scope exits (§11.4), in a recursive function
// too: a self-call in tail position runs while the caller's attachment still
// holds its arena, so the callee attaches that arena by the handle the
// caller saved, optimized, where the self-call could have become a loop, as
// not. The first two tests are written so that they are no base case to copy
// to the call; the last two are, and the copy, run in the caller, declares
// the callee's attachment in a block of its own, while the caller's holds.
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

recursive fn walk_copied(n: i64) -> i64 {
    let sh = shared {};
    if n > 0 {
        saved = sh.handle;
        return walk_copied(n - 1);
    }
    let parent = attach(saved);
    n
}

recursive fn total_copied(n: i64) -> i64 {
    let sh = shared {};
    if n > 0 {
        saved = sh.handle;
        return n + total_copied(n - 1);
    }
    let parent = attach(saved);
    0
}

fn main() {
    print(walk(2));           // 0
    print(total(4));          // 10
    print(walk_copied(2));    // 0
    print(total_copied(4));   // 10
}
