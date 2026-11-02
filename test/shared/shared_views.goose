// Views of mapped files (§11.4): every plain type, read in place at its
// alignment; a struct with a pad; bounds up to the size, an empty view at the
// end and an empty file; views through shared& parameters, kept in containers
// and read back, and a global attachment's in globals; the refusals map_file
// reports; and a file renamed and replaced while it is mapped.
import os;

struct Pt { x: i32, pad 4, y: f64 }
struct Pair { lo: u16, hi: u16, n: i32[2] }

let DIR = "gs_shared_views";

fn path(name: const u8[:]) -> u8[>..] { str(DIR, "/", name) }

fn total(xs: const i64[:]) -> i64 {
    var s = 0;
    for x in xs { s += x; }
    s
}

// Through a parameter, a view is rooted at the caller's attachment, so it
// may be returned.
fn column(sh: shared&, m: resource<mapping>, first: i64, n: i64) -> const i64[:] {
    view<i64>(sh, m, first * 8, n)
}

// An unannotated binding borrows the attachment, as it borrows any owner.
fn halves(sh: shared&, m: resource<mapping>) -> i64 {
    let s = sh;
    let n = s.size(m) / 16;
    total(column(s, m, 0, n)) - total(column(s, m, n, n))
}

// Views held in a container rooted where the attachment is.
fn chunks(sh: shared&, m: resource<mapping>, k: i64) -> i64 {
    var parts: (const i64[:])[>..] = [];
    let n = sh.size(m) / 8;
    for i in k { parts.push(view<i64>(sh, m, i * (n / k) * 8, n / k)); }
    var s = 0;
    for p in parts { s += p[0] + p[p.len - 1]; }
    s
}

let gsh = shared {};
var gcols: (const i64[:])[>..];

fn main() {
    make_dir(DIR);
    var col: i64[>..] = [];
    for i in 64 { col.push(i * i - 100); }
    write_file(path("col.i64"), bytes_of(col));
    var pts: Pt[>..] = [];
    for i in 4 { pts.push(Pt { x: i as i32 * 3, y: i / 4.0 }); }
    write_file(path("pts"), bytes_of(pts));
    write_file(path("empty"), "");

    let sh = shared {};
    let m, ok = sh.map_file(path("col.i64"));
    print(ok, " ", sh.size(m));                                 // true 512

    // Each width, from the same bytes.
    let xs = view<i64>(sh, m, 0, 64);
    print(xs.len, " ", xs[0], " ", xs[63], " ", total(xs));      // 64 -100 3869 78944
    let ws = view<i32>(sh, m, 8, 4);
    print(ws[0], " ", ws[1], " ", ws[2], " ", ws[3]);            // -99 -1 -96 -1
    let us = view<u32>(sh, m, 8, 2);
    print(us[0], " ", us[1]);                                   // 4294967197 4294967295
    let bs = view<u8>(sh, m, 0, 8);
    print(bs[0], " ", bs[1], " ", bs[7]);                       // 156 255 255
    let hs = view<i16>(sh, m, 2, 3);
    print(hs[0], " ", hs[1], " ", hs[2]);                       // -1 -1 -1
    let qs = view<u64>(sh, m, 504, 1);
    print(qs[0]);                                               // 3869
    let ss = view<i8>(sh, m, 1, 1);
    print(ss[0]);                                               // -1
    let ps = view<Pair>(sh, m, 16, 2);
    print(ps[0].lo, " ", ps[0].hi, " ", ps[0].n[0], " ", ps[1].n[1]);   // 65440 65535 -1 -1
    let rows = view<i64[4]>(sh, m, 32, 2);
    print(rows[0][0], " ", rows[1][3]);                         // -84 21

    // Floats, and a struct with a pad, at the alignment of its widest scalar.
    let pm, pok = sh.map_file(path("pts"));
    let pv = view<Pt>(sh, pm, 0, 4);
    print(pok, " ", pv.len, " ", pv[3].x, " ", pv[3].y);         // true 4 9 0.75
    let fs = view<f64>(sh, pm, 8, 1);
    print(fs[0]);                                               // 0.0
    print(view<f32>(sh, pm, 4, 1).len);                         // 1

    // Up to the size: an empty view anywhere in it, the end included.
    print(view<i64>(sh, m, 512, 0).len, " ", view<u8>(sh, m, 511, 1)[0]);   // 0 0
    let em, eok = sh.map_file(path("empty"));
    print(eok, " ", sh.size(em), " ", view<i64>(sh, em, 0, 0).len);         // true 0 0

    // Through parameters, a borrowed binding, and a container of views.
    print(column(sh, m, 60, 4)[3], " ", halves(sh, m), " ", chunks(sh, m, 4));   // 3869 -64512 10148
    var mine: (const i64[:])[>..] = [];
    mine.push(xs[10..20]);
    mine.push(column(sh, m, 30, 2));
    print(mine[0][0], " ", mine[1][1]);                         // 0 861

    // A global attachment roots views in globals.
    let gm, gok = gsh.map_file(path("col.i64"));
    gcols.push(view<i64>(gsh, gm, 8, 1));
    print(gok, " ", gcols[0][0]);                               // true -99

    // The refusals, with their reasons.
    var why: u8[>..] = [];
    let mm, mok = sh.map_file(path("missing"), why);
    print(mok, " ", why.len > 0, " ", sh.size(m));              // false true 512
    why.clear();
    let dm, dok = sh.map_file(DIR, why);
    print(dok, " ", why);                                       // false gs_shared_views: a directory, not a regular file
    why.clear();
    let nm, nok = sh.map_file("col\0x", why);
    print(nok, " ", why);                                       // false col: the path holds a NUL byte
    print(mm, " ", dm, " ", nm);

    // A rename leaves a mapping alone, and so does a new file at the name.
    let rm, rok = sh.map_file(path("pts"));
    rename_file(path("pts"), path("pts2"));
    write_file(path("pts"), "replaced");
    let am, aok = sh.map_file(path("pts"));
    print(rok, " ", view<Pt>(sh, rm, 16, 1)[0].x, " ", sh.size(am));   // true 3 8
    let bm, bok = sh.map_file(path("pts2"));
    print(bok, " ", view<Pt>(sh, bm, 48, 1)[0].y);              // true 0.75

    delete_file(path("col.i64"));
    delete_file(path("pts"));
    delete_file(path("pts2"));
    delete_file(path("empty"));
    delete_dir(DIR);
}
