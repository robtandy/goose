// select<E> (§11.2) takes the next message of a type that a variant of E
// holds and returns it in that variant, from the caller's inbox before the
// global queue. Each site starts after the variant it returned last, so a
// type with a message is taken within as many calls as E has variants, and
// a busy type starves no other. select<E>(ms) waits at most ms
// milliseconds, polls at zero or less, and gives E's zero value and false
// on a miss, but a waiting message whatever its timeout. E may be generic,
// and in variable mode for a variable-size message.
import os;

struct Job { n: i64 }
struct Control { stop: bool }
enum Signal { Wake, Sleep }
struct Text { body: u8[] }
enum Work { Job { j: Job }, Control { c: Control }, Sig { s: Signal } }
enum Var { Line { t: Text }, Count { n: i64 } }
enum Msg<T> { Data { d: T }, Done { c: Control } }

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

fn show(w: const Work) -> u8[>..] {
    match w {
        Job j => str("job ", j.j.n),
        Control c => str("control ", c.c.stop),
        Sig s => str("signal ", s.s),
    }
}

thread_fn flood(n: i64) {
    for i in n { qput(Job { n: i }); }
}

thread_fn late(ms: i64) {
    sleep_ms(ms);
    qput_to(-1, Control { stop: true });
}

// A program's own function of the name keeps its calls.
fn select(a: i64, b: i64, first: bool) -> i64 { if first { a } else { b } }

fn main() {
    // Each type into its variant, the site's rotation going round them.
    let sleep: Signal = Signal.Sleep;
    qput(sleep);
    qput(Control { stop: false });
    qput(Job { n: 1 });
    var seen: u8[>..] = [];
    for i in 3 { format(seen, show(select<Work>()), "; "); }
    print(seen);

    // The inbox first, within a type; then the global queue.
    qput(Job { n: 2 });
    qput_to(-1, Job { n: 3 });
    let a = select<Work>();
    let b = select<Work>();
    print(show(a), ", then ", show(b));

    // Types take turns: three of each, alternately.
    for i in 3 {
        qput(Job { n: 10 + i });
        qput(Control { stop: i == 2 });
    }
    seen.clear();
    for i in 6 { format(seen, show(select<Work>()), "; "); }
    print(seen);

    // A flooded type starves no other: the control comes within three calls,
    // from the global queue or from the inbox.
    let f = thread_spawn(flood, 100000);
    take<Job>();
    qput(Control { stop: true });
    var calls = 0;
    loop {
        calls++;
        match select<Work>() {
            Control c => { break; },
            Job j => {},
            Sig s => {},
        }
    }
    print("a control among a flood of jobs, within three selects: ", calls <= 3);
    thread_wait(f);
    for i in 1000 { qput_to(-1, Job { n: i }); }
    qput(Control { stop: true });
    calls = 0;
    loop {
        calls++;
        let w = select<Work>();
        let stop = match w { Control c => true, Job j => false, Sig s => false };
        if stop { break; }
    }
    print("and among a full inbox: ", calls <= 3);
    loop {
        let x, more = select<Work>(0);
        if !more { break; }
    }

    // Timeouts: none to wait, a few milliseconds, and a message that comes
    // while waiting; a waiting message whatever the timeout.
    let z, gotz = select<Work>(0);
    let n, gotn = select<Work>(-3);
    print(show(z), " ", gotz, ", ", show(n), " ", gotn);
    let t0 = clock_ns();
    let m, gotm = select<Work>(15);
    let waited = (clock_ns() - t0) / 1000000;
    print(show(m), " ", gotm, " after waiting: ", waited >= 5 && waited < 5000);
    let l = thread_spawn(late, 15);
    let c, gotc = select<Work>(60000);
    print(show(c), " ", gotc);
    thread_wait(l);
    qput(Job { n: 7 });
    let w0, gotw0 = select<Work>(0);
    print(show(w0), " ", gotw0);

    // A generic E.
    qput(5);
    qput(Control { stop: true });
    for i in 2 {
        match select<Msg<i64>>() {
            Data d => print("data ", d.d),
            Done c => print("done ", c.c.stop),
        }
    }

    // E in variable mode, for a variable-size message.
    qput(Text { body: "hello" });
    qput(42);
    for i in 2 {
        let v = select<Var..>();
        match v {
            Line t => print("line ", t.t.body),
            Count k => print("count ", k.n),
        }
    }
    let e, gote = select<Var..>(0);
    match e {
        Line t => print("missed: line '", t.t.body, "' ", gote),
        Count k => print("missed: count ", k.n, " ", gote),
    }

    print(select(1, 2, false));
}
