// What only the runtime can know about views and attachments is checked
// there (§9.3, §11.4), each by an abort that ends only the contained worker
// it is in: a view out of its mapping's bounds, at a negative offset or
// count, or too long to fit even counted without overflow, or at an offset
// that is not aligned; a view or size of the zero handle, or of another
// arena's mapping; an attach of the zero handle or of a released arena.
// Each message names what failed; main goes on, and prints them.
import os;

let DIR = "gs_shared_aborts";

struct Pt { x: i32, y: i32 }

thread_fn check(kind: i64, h: resource<shared>, m: resource<mapping>, off: i64) {
    let sh = attach(h);
    if kind == 0 { print(view<i64>(sh, m, 8, 4).len); }
    if kind == 1 { print(view<i64>(sh, m, 8, 8).len); }
    if kind == 2 { print(view<i64>(sh, m, off - 16, 1).len); }
    if kind == 3 { print(view<u8>(sh, m, 0, off - 9).len); }
    if kind == 4 { print(view<Pt>(sh, m, 0, (1 << 62) + off).len); }
    if kind == 5 { print(view<i64>(sh, m, off + 4, 1).len); }
    if kind == 6 { print(view<Pt>(sh, m, off + 2, 1).len); }
    if kind == 7 { print(view<i64>(sh, default<resource<mapping>>(), 0, 0).len); }
    if kind == 8 { print(sh.size(default<resource<mapping>>())); }
    if kind == 9 {
        let other = shared {};
        print(view<i64>(other, m, 0, 1).len);
    }
    if kind == 10 {
        let other = shared {};
        print(other.size(m));
    }
}

thread_fn attacher(h: resource<shared>) {
    let sh = attach(h);
    print("attached");
}

// The message up to its location.
fn located(msg: u8[:]) -> i64 {
    var i = msg.len;
    while i > 0 && msg[i - 1] != '(' { i--; }
    if i < 2 { return msg.len; }
    i - 2
}

fn report(what: const u8[:], id: i64) {
    var why: u8[>..] = [];
    let ok = thread_wait(id, why);
    print(what, ": ", ok, " ", why[..located(why)]);
}

fn main() {
    make_dir(DIR);
    let p = str(DIR, "/col.i64");
    var col: i64[>..] = [];
    for i in 8 { col.push(i); }
    write_file(p, bytes_of(col));
    let sh = shared {};
    let m, ok = sh.map_file(p);
    for kind in 11 { report(str("check ", kind), thread_spawn_contained(check, kind, sh.handle, m, 8)); }
    report("attach of the zero handle",
           thread_spawn_contained(attacher, default<resource<shared>>()));
    let gone = {
        let tmp = shared {};
        tmp.handle
    };
    report("attach of a released arena", thread_spawn_contained(attacher, gone));
    report("attach of a live arena", thread_spawn_contained(attacher, sh.handle));
    print("main goes on: ", view<i64>(sh, m, 56, 1)[0]);
    delete_file(p);
    delete_dir(DIR);
}
