// A construct picking between pools hands the one it takes to a thread_pool&
// parameter by reference, and one whose branches each make a pool makes the
// one it takes: neither is a second handle to a pool, as a construct copying
// a pool variable would be (errors_tc/pool_copy_branch.goose). Closing
// through the parameter closes the variable the construct picked.
fn fill(chunk: i64[:], idx: i64) {
    for &x in chunk { x = idx + 1; }
}

fn run_on(p: thread_pool&, data: i64[:]) {
    p.apply(chunks(data, 2), fill);
}

fn end_pool(p: thread_pool&) {
    p.close();
}

fn main() {
    var a = thread_pool(2);
    var b = thread_pool(2);
    defer b.close();
    var data: i64[>..] = [0, 0, 0, 0];
    for i in 2 {
        run_on(if i == 0 { a } else { b }, data);
    }
    print(data);
    let first = true;
    end_pool(if first { a } else { b });
    a.close();   // closed already through end_pool: nothing to do
    let many = true;
    var c = if many { thread_pool(4) } else { thread_pool(1) };
    defer c.close();
    c.apply(chunks(data, 1), fill);
    print(data);
}
