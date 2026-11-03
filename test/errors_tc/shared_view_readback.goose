// error: .index_of needs a reference rooted at the array itself
// error: it was read out of views and may point into gsh or nums
// An attachment's storage holds plain data (§9.5, §11.4): a view read back
// out of a container may point into the attachment, as here, where it does,
// so it names no one array and is no element of nums.
let gsh = shared {};
var nums:  i64[>..]            = [];
var views: (const i64[:])[>..] = [];

fn stash() {
    let m, ok = gsh.map_file("col.i64");
    views.push(view<i64>(gsh, m, 0, 1));
}

fn main() {
    nums.push(1);
    stash();
    let v = views[0];
    print(nums.index_of(v[0]));
}
