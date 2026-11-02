// A program's functions named like the attachment's builtins (§11.4) take
// the plain calls they match, and the builtin takes a call whose first
// argument is an attachment, or a reference to one, however it is reached:
// by name, through a struct's reference field, through a reference
// parameter, or as the receiver of a member call (size, map_file).
import os;

struct Holder { sh: shared&, n: i64 }

let DIR = "gs_shared_builtin_names";

// The program's own, unrelated to the attachment's.
fn view(words: const u8[:]) -> i64 { words.len }
fn size(n: i64) -> i64 { n * 2 }
fn map_file(words: const u8[:], n: i64) -> i64 { words.len + n }

fn first(holder: Holder&, m: resource<mapping>) -> i64 { view<i64>(holder.sh, m, 0, 1)[0] }

fn main() {
    make_dir(DIR);
    let p = str(DIR, "/xs");
    var xs: i64[>..] = [7, 8];
    write_file(p, bytes_of(xs));
    let sh = shared {};
    let m, ok = sh.map_file(p);
    let holder = Holder { sh: sh, n: 1 };
    print(view<i64>(holder.sh, m, 0, 1)[0], " ", view<i64>(sh, m, 8, 1)[0]);   // 7 8
    print(size(holder.sh, m), " ", holder.sh.size(m), " ", size(sh, m));       // 16 16 16
    let m2, ok2 = map_file(holder.sh, p);
    let m3, ok3 = holder.sh.map_file(p);
    print(ok2, " ", ok3, " ", view<i64>(holder.sh, m2, 8, 1)[0]);                // true true 8
    print(first(holder, m));                                                     // 7
    print(view("abc"), " ", size(21), " ", map_file("ab", 1));                   // 3 42 3

    delete_file(p);
    delete_dir(DIR);
}
