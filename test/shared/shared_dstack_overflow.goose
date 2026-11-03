// runtime-define: GS_STACK_RESERVE=1048576
// A dynamic stack growing past its slot, a data stack's reservation (here
// 1 MB, GS_STACK_RESERVE), runs into the slot's guard gap, which ends the
// program with a message naming the dynamic stack's declaration and what
// raises a slot's size, as a data stack's overrun does (§10.4, §11.4).
fn main() {
    var ds = dynamic_stack<i64> {};
    for i in 100000 { ds.items.push(i); }
    print("100000 fit: ", ds.items.len);
    for i in 200000 { ds.items.push(i); }
    print("never printed");
}
