// error: returning a reference rooted in sh, which dies with this function
// A frozen array's view is rooted at the attachment it was made through,
// which ends with the function (§9.2, §11.4).
struct Row { key: i64 }

fn rows(r: resource<frozen<Row>>) -> const Row[:] {
    let sh = shared {};
    sh.view(r)
}

fn main() {}
