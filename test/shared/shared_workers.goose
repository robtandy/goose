// Handles cross threads, and views stay in theirs (§11.2, §11.4): workers
// given an arena's handle and a mapping's, as thread arguments and through a
// queue, attach on their own and view the one mapping main made, 1, 2 and
// 16 of them at once; and an arena a worker made and mapped a file into,
// which main attaches to before the worker's attachment ends, and keeps.
import os;

let DIR = "gs_shared_workers";
let N = 1 << 16;    // i64s in the column

struct Job { arena: resource<shared>, col: resource<mapping>, first: i64, count: i64 }
struct Part { worker: i64, first: i64, sum: i64 }
struct Made { arena: resource<shared>, file: resource<mapping> }

fn sum(xs: const i64[:]) -> i64 {
    var s = 0;
    for x in xs { s += x; }
    s
}

// Its job as an argument: an attachment of its own, and a view of its part.
thread_fn summer(w: i64, job: Job) {
    let sh = attach(job.arena);
    let xs = view<i64>(sh, job.col, job.first * 8, job.count);
    qput(Part { worker: w, first: job.first, sum: sum(xs) });
}

// Its jobs through a queue, until one with no rows: one attachment, many
// views.
thread_fn server(w: i64, arena: resource<shared>) {
    let sh = attach(arena);
    loop {
        let job = qget<Job>();
        guard job.count > 0 else { break; }
        qput(Part { worker: w, first: job.first, sum: sum(view<i64>(sh, job.col, job.first * 8,
                                                                       job.count)) });
    }
}

// An arena of its own, a file mapped into it, and the handles to main, whose
// attachment keeps both once this one ends.
thread_fn maker(path: u8[64], n: i64) {
    let sh = shared {};
    let m, ok = sh.map_file(path[..n]);
    qput(Made { arena: sh.handle, file: m });
    qget<bool>();   // main has attached
}

// The parts' sums, however the workers' puts interleave.
fn collect(k: i64) -> i64 {
    var s = 0;
    for i in k { s += qget<Part>().sum; }
    s
}

fn main() {
    make_dir(DIR);
    let p = str(DIR, "/col.i64");
    var col: i64[>..] = [];
    for i in N { col.push((i * 7919) % 1000 - 500); }
    write_file(p, bytes_of(col));
    var expect = 0;
    for x in col { expect += x; }

    let sh = shared {};
    let m, ok = sh.map_file(p);
    print(ok, " ", sh.size(m), " ", sum(view<i64>(sh, m, 0, N)) == expect);

    // 1, 2 and 16 workers, a part each, as arguments.
    for k in [1, 2, 16] {
        var ids: i64[>..] = [];
        let part = N / k;
        for w in k {
            ids.push(thread_spawn(summer, w, Job { arena: sh.handle, col: m, first: w * part,
                                                   count: part }));
        }
        let s = collect(k);
        for id in ids { thread_wait(id); }
        print(k, " workers: ", s == expect);
    }

    // 4 workers serving 64 jobs from a queue.
    var ids: i64[>..] = [];
    for w in 4 { ids.push(thread_spawn(server, w, sh.handle)); }
    for j in 64 { qput(Job { arena: sh.handle, col: m, first: j * (N / 64), count: N / 64 }); }
    let s = collect(64);
    for w in 4 { qput(Job { arena: sh.handle, col: m, first: 0, count: 0 }); }
    for id in ids { thread_wait(id); }
    print("64 jobs: ", s == expect);

    // A worker's arena, attached here before its attachment ends.
    var buf: u8[64] = [0; 64];
    for i in p.len { buf[i] = p[i]; }
    let id = thread_spawn(maker, buf, p.len);
    let made = qget<Made>();
    let theirs = attach(made.arena);
    qput(true);
    thread_wait(id);
    print("the worker's mapping: ", theirs.size(made.file), " ",
          sum(view<i64>(theirs, made.file, 0, N)) == expect);

    delete_file(p);
    delete_dir(DIR);
}
