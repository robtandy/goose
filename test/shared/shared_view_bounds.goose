// A view that does not fit its mapping ends the program on main's thread
// (§9.3, §11.4), with a message naming the file, the type, the count and
// the offset, and the file's size. The file is gone by then: a mapping
// outlives its file's name.
import os;

let DIR = "gs_shared_view_bounds";

fn main() {
    make_dir(DIR);
    let p = str(DIR, "/col");
    var col: i64[>..] = [1, 2, 3];
    write_file(p, bytes_of(col));
    let sh = shared {};
    let m, ok = sh.map_file(p);
    delete_file(p);
    delete_dir(DIR);
    print(view<i64>(sh, m, 0, 3)[2]);
    print(view<i64>(sh, m, 8, 3).len);
}
