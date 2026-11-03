// Addressed delivery (§11.2): qput_to(id, v) puts v in thread id's inbox for
// v's type, every take looks at the caller's inbox before the global queue,
// and thread_id() names the caller, main being -1. A put that returned
// before another started is taken first, so each sender's messages arrive
// in order. A worker's inboxes take puts before it starts; once it has
// ended, a put to it is false, and what it never took is gone with it.
import os;

struct Job { key: i64, from: i64 }
struct Reply { key: i64, value: i64, by: i64 }
struct Note { n: i64 }
struct Seq { from: i64, n: i64 }
struct Go { at: i64 }

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

// Answers each job to the thread named in it, until a negative key.
thread_fn worker(k: i64) {
    loop {
        let j = take<Job>();
        if j.key < 0 { break; }
        qput_to(j.from, Reply { key: j.key, value: j.key * k, by: thread_id() });
    }
}

// Sends n numbered messages to main's inbox.
thread_fn sender(i: i64, n: i64) {
    for k in n { qput_to(-1, Seq { from: i, n: k }); }
}

// A worker that sleeps before it looks, so that main's put finds it not yet
// taking; its own inbox is where it puts a note to itself.
thread_fn late(ms: i64) {
    sleep_ms(ms);
    qput_to(thread_id(), Note { n: 70 });
    let a = take<Note>();
    let b = take<Note>();
    qput_to(-1, Reply { key: a.n, value: b.n, by: thread_id() });
}

// Never takes a Note, though main puts some in its inbox.
thread_fn ignores() {
    take<Go>();
}

thread_fn fails() {
    assert(false);
}

fn main() {
    print("main is ", thread_id());

    // Jobs to particular workers, answered to main's inbox.
    let a = thread_spawn(worker, 10);
    let b = thread_spawn(worker, 100);
    for i in 3 {
        qput_to(a, Job { key: i + 1, from: thread_id() });
        qput_to(b, Job { key: i + 1, from: -1 });
    }
    var fromA = 0;
    var fromB = 0;
    var wrong = 0;
    for i in 6 {
        let r = take<Reply>();
        if r.by == a && r.value == r.key * 10 { fromA += r.value; }
        else if r.by == b && r.value == r.key * 100 { fromB += r.value; }
        else { wrong++; }
    }
    print("from a ", fromA, ", from b ", fromB, ", wrong ", wrong);
    qput_to(a, Job { key: -1, from: -1 });
    qput_to(b, Job { key: -1, from: -1 });
    thread_wait(a);
    thread_wait(b);

    // The inbox first, each queue in order.
    qput(Note { n: 1 });
    qput_to(-1, Note { n: 2 });
    qput(Note { n: 3 });
    qput_to(-1, Note { n: 4 });
    print(take<Note>().n, " ", take<Note>().n, " ", take<Note>().n, " ", take<Note>().n);
    // qpoll and a timed qget read the inbox too.
    qput_to(thread_id(), Note { n: 5 });
    let p, gotp = qpoll<Note>();
    let q, gotq = qpoll<Note>();
    let w, gotw = qget<Note>(10);
    print(p.n, " ", gotp, " ", q.n, " ", gotq, " ", w.n, " ", gotw);

    // A worker's inbox takes puts before the worker starts.
    let l = thread_spawn(late, 30);
    print("before it starts: ", qput_to(l, Note { n: 60 }));
    let lr = take<Reply>();
    print("it took ", lr.key, " then ", lr.value, ", by itself ", lr.by == l);
    thread_wait(l);

    // Each sender's messages in the order it put them, among the others'.
    var senders: i64[>..] = [];
    for i in 4 { senders.push(thread_spawn(sender, i, 2000)); }
    var next: i64[4] = [0, 0, 0, 0];
    var outoforder = 0;
    for i in 8000 {
        let s = take<Seq>();
        if s.n != next[s.from] { outoforder++; }
        next[s.from] = s.n + 1;
    }
    for id in senders { thread_wait(id); }
    print("8000 messages from 4 senders, out of order: ", outoforder);

    // Messages of every size class.
    var bulk: u8[>..] = [];
    bulk.resize(5000, 'b');
    let text: u8[] = "variable";
    qput_to(-1, bulk);
    qput_to(-1, text);
    print(qget<u8[>..]>().len, " ", qget<u8[]>());

    // qlimit<T> limits the global queue alone.
    qlimit<Note>(1);
    print(qput_to(-1, Note { n: 6 }), " ", qput_to(-1, Note { n: 7 }), " ", qput(Note { n: 8 }),
          " ", qput(Note { n: 9 }));
    print(take<Note>().n, " ", take<Note>().n, " ", take<Note>().n);
    qlimit<Note>(1000);

    // A worker that has ended: false, and nothing queued; one that aborted
    // while contained too. What a worker never took is gone with it.
    let i = thread_spawn(ignores);
    print("to a live worker: ", qput_to(i, Note { n: 10 }), " ", qput_to(i, Note { n: 11 }));
    qput_to(i, Go { at: 0 });
    thread_wait(i);
    print("to an ended worker: ", qput_to(i, Note { n: 12 }));
    let f = thread_spawn_contained(fails);
    print("aborted: ", !thread_wait(f), ", a put: ", qput_to(f, Note { n: 13 }));
    let left, gotleft = qpoll<Note>();
    print("left over: ", gotleft);
}
