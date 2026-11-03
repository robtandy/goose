// runtime-define: GS_DYNAMIC_BUDGET=8595177472ull
// A dynamic budget of four slots (§11.4, GS_DYNAMIC_BUDGET; --dynamic-budget
// sets it): a contained worker freezing an array at a time into main's arena
// takes one slot for each array and one for its dynamic stack, and the
// freeze that finds every slot live or frozen aborts with the budget, the
// slots' size and count and what raises it. The worker's end frees its
// dynamic stack's slot, which main's dynamic stack takes, while the arrays
// it froze keep theirs with main's arena, whose end frees them for four
// dynamic stacks at once.

thread_fn filler(arena: resource<shared>) {
    let sh = attach(arena);
    var ds = dynamic_stack<i64> {};
    for i in 10 {
        ds.items.push(i);
        let r = sh.freeze(ds);
        print("frozen ", i + 1);
    }
}

// The message up to its location.
fn located(msg: u8[:]) -> i64 {
    var i = msg.len;
    while i > 0 && msg[i - 1] != '(' { i--; }
    if i < 2 { return msg.len; }
    i - 2
}

fn main() {
    {
        let sh = shared {};
        var why: u8[>..] = [];
        print("the filler returned: ", thread_wait(thread_spawn_contained(filler, sh.handle), why));
        print(why[..located(why)]);
        var mine = dynamic_stack<i64> {};
        mine.items.push(7);
        print("main's dynamic stack on the slot the worker gave back: ", mine.items[0]);
    }
    var a = dynamic_stack<i64> {};
    var b = dynamic_stack<i64> {};
    var c = dynamic_stack<i64> {};
    var d = dynamic_stack<i64> {};
    a.items.push(1);
    d.items.push(4);
    print("four at once once the arena is gone: ", a.items[0] + d.items[0]);
}
