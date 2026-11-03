// The attachment's builtins evaluate their arguments in order, each once,
// as every call does (§4.1, §7.1): a later argument that assigns the handle
// an earlier one named, or rebinds the reference the receiver is reached
// through, changes nothing the call already took. And map_file's `why` is
// evaluated whether the file maps or not.
import os;

let DIR = "gs_shared_argument_order";

fn main() {
    make_dir(DIR);
    let pa = str(DIR, "/a");
    let pb = str(DIR, "/b");
    var ca: i64[>..] = [1, 2];
    var cb: i64[>..] = [3, 4, 5];
    write_file(pa, bytes_of(ca));
    write_file(pb, bytes_of(cb));
    let sa = shared {};
    let sb = shared {};
    var m, ok = sa.map_file(pa);
    let mb, okb = sa.map_file(pb);
    let mo, oko = sb.map_file(pb);

    // A later argument assigns m: the view is of the mapping m named first.
    fn retarget() -> i64 {
        m = mb;
        0
    }
    print(view<i64>(sa, m, retarget(), 1)[0]);                  // 1
    print(view<i64>(sa, m, 0, 1)[0]);                           // 3: m was assigned

    // A later argument rebinds the receiver's reference: the call goes to
    // the attachment it named first.
    var r: shared& = sa;
    fn to_b() -> i64 {
        r .= sb;
        0
    }
    fn to_b_path() -> const u8[:] {
        r .= sb;
        pa
    }
    fn to_b_mapping() -> resource<mapping> {
        r .= sb;
        mb
    }
    print(view<i64>(r, mb, to_b(), 1)[0]);                      // 3, through sa
    r .= sa;
    let mr, okr = r.map_file(to_b_path());
    print(okr, " ", sa.size(mr));                               // true 16: in sa's arena
    r .= sa;
    print(r.size(to_b_mapping()));                              // 24: sa's mapping, through sa
    print(view<i64>(r, mo, 16, 1)[0]);                          // 5: r is sb now

    // `why` is evaluated on success too, and appended to on failure.
    var why: u8[>..] = [];
    var asked = 0;
    fn output() -> u8[>..]& {
        asked += 1;
        why
    }
    let m1, ok1 = sa.map_file(pa, output());
    print(ok1, " ", asked, " ", why.len);                       // true 1 0
    let m2, ok2 = sa.map_file(str(DIR, "/none"), output());
    print(ok2, " ", asked, " ", why.len > 0);                   // false 2 true

    delete_file(pa);
    delete_file(pb);
    delete_dir(DIR);
}
