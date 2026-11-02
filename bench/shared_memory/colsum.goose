// Summing an i64 column from a file in the page cache, in Goose (README.md,
// "The implementation"): through views of one shared mapping (§11.4), by
// pread into a buffer each worker reuses (colsum_impl.c, an extern fn), and
// from the whole file read into Goose memory with os's read_file, whose
// parts reach the workers as copies, as memory crosses threads without
// shared memory.
//
//     goose build -O2 bench/shared_memory/colsum.goose
//     ./colsum FILE MODE THREADS [PASSES]
//
// MODE is view, pread or read_file. Workers take morsels of 983,040 bytes
// (122,880 i64s) from a queue, as bench/shared_memory/mapbench.c's take
// them from a counter; read_file's are given their parts as copies, and
// one thread is main's, which read the file. THREADS 0 sums on main's
// thread. A view pass includes mapping the file on the first
// pass; later passes scan the mapping again, its page tables populated. A
// read_file pass includes reading the file.
import os;
import std;
import math;

let MORSEL = 983040;

extern fn col_open(path: const u8[:]) -> i64;
extern fn col_pread(fd: i64, off: i64, buf: i64[:]) -> i64;
extern fn col_close(fd: i64);

struct Sum { s: i64 }

checkfree fn sum(xs: const i64[:]) -> i64 {
    var s = 0;
    for x in xs { s += x; }
    s
}

// The i64s of bytes read from a file, which only a view can see as i64s
// without a copy: no check is left, and the C compiler makes each eight
// loads one.
checkfree fn sum_bytes(b: const u8[:]) -> i64 {
    var s = 0;
    var rest = b;
    while rest.len >= 8 {
        let lo: u32 = rest[0] | (rest[1] as u32 << 8) | (rest[2] as u32 << 16) |
                      (rest[3] as u32 << 24);
        let hi: u32 = rest[4] | (rest[5] as u32 << 8) | (rest[6] as u32 << 16) |
                      (rest[7] as u32 << 24);
        let w: u64 = lo | (hi as u64 << 32);
        s += w as! i64;
        rest = rest[8..];
    }
    s
}

// The morsel a worker takes next, an offset and a count: -1 at the end.
fn morsel(size: i64) -> i64, i64 {
    let k = qget<i64>();
    if k < 0 { return -1, 0; }
    let off = k * MORSEL;
    return off, min(MORSEL, size - off) / 8;
}

thread_fn viewer(h: resource<shared>, m: resource<mapping>, size: i64) {
    let sh = attach(h);
    var s = 0;
    loop {
        let off, n = morsel(size);
        guard off >= 0 else { break; }
        s += sum(view<i64>(sh, m, off, n));
    }
    qput(Sum { s: s });
}

thread_fn preader(fd: i64, size: i64) {
    var buf: i64[>..] = [];
    buf.resize(MORSEL / 8, 0);
    var s = 0;
    loop {
        let off, n = morsel(size);
        guard off >= 0 else { break; }
        col_pread(fd, off, buf[..n]);
        s += sum(buf[..n]);
    }
    qput(Sum { s: s });
}

thread_fn copied(part: u8[>..]) { qput(Sum { s: sum_bytes(part) }); }

// The morsels of a scan, to the workers spawned for it, and their sums.
fn morsels(threads: i64, size: i64) -> i64 {
    for k in (size + MORSEL - 1) / MORSEL { qput(k); }
    for t in threads { qput(-1); }
    var s = 0;
    for t in threads { s += qget<Sum>().s; }
    s
}

fn ms(ns: i64) -> f64 { round(ns / 1e5) / 10.0 }

// A pass from t0, and its part before t1 where that is later than t0.
fn report(mode: const u8[:], threads: i64, pass: i64, size: i64, t0: i64, t1: i64, s: i64) {
    let ns = clock_ns() - t0;
    var part: u8[>..] = [];
    if t1 > t0 { format(part, ", reading ", ms(t1 - t0), " ms"); }
    print(mode, " threads=", threads, " pass=", pass, ": ", ms(ns), " ms", part, ", ",
          round(size / (ns / 1e9) / 1e7) / 100.0, " GB/s (sum ", s, ")");
}

fn main() {
    let a = args();
    if a.len < 4 {
        print("usage: colsum FILE view|pread|read_file THREADS [PASSES]");
        exit(2);
    }
    let path = a[1];
    let mode = a[2];
    let threads, tok = parse_int(a[3]);
    var passes = 1;
    if a.len > 4 {
        let p, pok = parse_int(a[4]);
        passes = p;
    }
    if mode == "view" {
        var t0 = clock_ns();
        let sh = shared {};
        var why: u8[>..] = [];
        let m, ok = sh.map_file(path, why);
        if !ok {
            print(why);
            exit(1);
        }
        let size = sh.size(m);
        for pass in passes {
            var s = 0;
            if threads == 0 {
                s = sum(view<i64>(sh, m, 0, size / 8));
            } else {
                var ids: i64[>..] = [];
                for t in threads { ids.push(thread_spawn(viewer, sh.handle, m, size)); }
                s = morsels(threads, size);
                for id in ids { thread_wait(id); }
            }
            report(mode, threads, pass, size, t0, 0, s);
            t0 = clock_ns();
        }
    } else if mode == "pread" {
        let fd = col_open(path);
        let sh = shared {};
        let m, ok = sh.map_file(path);
        let size = sh.size(m);
        for pass in passes {
            let t0 = clock_ns();
            var s = 0;
            if threads == 0 {
                var buf: i64[>..] = [];
                buf.resize(MORSEL / 8, 0);
                for k in (size + MORSEL - 1) / MORSEL {
                    let n = min(MORSEL, size - k * MORSEL) / 8;
                    col_pread(fd, k * MORSEL, buf[..n]);
                    s += sum(buf[..n]);
                }
            } else {
                var ids: i64[>..] = [];
                for t in threads { ids.push(thread_spawn(preader, fd, size)); }
                s = morsels(threads, size);
                for id in ids { thread_wait(id); }
            }
            report(mode, threads, pass, size, t0, 0, s);
        }
        col_close(fd);
    } else if mode == "read_file" {
        for pass in passes {
            let t0 = clock_ns();
            var bytes: u8[>..] = [];
            read_file(path, bytes);
            let t1 = clock_ns();
            let size = bytes.len;
            var s = 0;
            if threads <= 1 {
                s = sum_bytes(bytes);
            } else {
                var ids: i64[>..] = [];
                let part = (size / 8 + threads - 1) / threads * 8;
                for t in threads {
                    let lo = min(t * part, size);
                    ids.push(thread_spawn(copied, bytes[lo..min(lo + part, size)]));
                }
                for t in threads { s += qget<Sum>().s; }
                for id in ids { thread_wait(id); }
            }
            report(mode, threads, pass, size, t0, t1, s);
        }
    } else {
        print("unknown mode ", mode);
        exit(2);
    }
}
