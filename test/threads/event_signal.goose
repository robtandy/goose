// Events from C (§11.2, §7.10): event(v) makes an event of the calling
// thread holding a copy of v, a resource<event> that C keeps and signals
// with gs_event_signal from threads of its own. A signal makes the copy
// pending in the owner's inbox, or merges into the one pending, and wakes
// the owner, which takes it as any message: with qget, or in a select
// beside queued messages. It returns 1 then, 0 once the event is closed,
// by event_close or its thread's end, and -1 for the zero handle. The C
// beside this program (event_signal.build) is the I/O layer. Last, eight C
// threads signal 4000 times each, each waiting for a take after its
// signal: a wake-up lost between a signal and the owner's sleep would
// leave one waiting.
import os;

struct IoDone { file: i64 }
struct Over { k: i64 }
struct Tick { n: i64 }
struct Handle { e: resource<event> }
enum Io { Done { d: IoDone }, Over { o: Over }, Tick { t: Tick } }

extern fn io_after(e: resource<event>, done: resource<event>, count: i64, us: i64) -> i64;
extern fn io_signal(e: resource<event>) -> i64;
extern fn io_storm(e: resource<event>, over: resource<event>, threads: i64, rounds: i64) -> i64;
extern fn io_taken();
extern fn io_lost() -> i64;

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

fn next() -> Io {
    let m, got = select<Io>(60000);
    assert(got);
    m
}

// Makes an event and hands it to main, then ends, which closes it.
thread_fn owner() {
    qput(Handle { e: event(IoDone { file: 9 }) });
}

thread_fn ticker(to: i64, n: i64) {
    for i in n {
        sleep_ms(1);
        qput_to(to, Tick { n: i });
    }
}

fn main() {
    // A signal on this thread, the copy taken as a message.
    let e = event(IoDone { file: 3 });
    print(e, ": ", io_signal(e), " ", io_signal(e), " ", take<IoDone>().file);
    let more, gotmore = qpoll<IoDone>();
    print("two signals, one copy: ", !gotmore);
    print("the zero handle: ", io_signal(default<resource<event>>()));

    // A C thread's signal wakes main, asleep in select.
    let over = event(Over { k: 1 });
    io_after(e, default<resource<event>>(), 1, 20000);
    match next() {
        Done d => print("woken by C: done ", d.d.file),
        Over o => print("over?"),
        Tick t => print("tick?"),
    }

    // A burst merges into fewer copies, and the last signal is taken after
    // it: the burst's thread signals `over` once it is done.
    io_after(e, over, 1000, 0);
    var copies = 0;
    loop {
        match next() {
            Done d => { copies++; },
            Over o => { break; },
            Tick t => {},
        }
    }
    let late, gotlate = qpoll<IoDone>();
    if gotlate { copies++; }
    print("1000 signals in a burst: between 1 and 1000 copies: ", copies >= 1 && copies <= 1000);

    // Copies and queued messages of several types in one select: a ticker
    // on this inbox, C threads on two events.
    let t = thread_spawn(ticker, thread_id(), 20);
    io_after(e, default<resource<event>>(), 5, 3000);
    io_after(over, default<resource<event>>(), 1, 30000);
    var ticks = 0;
    var dones = 0;
    var overs = 0;
    while ticks < 20 || overs < 1 || dones < 1 {
        match next() {
            Done d => { dones++; },
            Over o => { overs++; },
            Tick k => { ticks++; },
        }
    }
    thread_wait(t);
    print("ticks ", ticks, ", copies of both events: ", dones >= 1 && overs >= 1);
    pause_and_drain();

    // Closed: later signals return 0, from any thread.
    event_close(e);
    print("closed: ", io_signal(e));
    let o = thread_spawn(owner);
    let h = take<Handle>();
    thread_wait(o);
    print("its thread ended: ", io_signal(h.e));

    // The storm.
    let s = event(IoDone { file: 4 });
    io_storm(s, over, 8, 4000);
    var takes = 0;
    loop {
        match next() {
            Done d => {
                takes++;
                io_taken();
            },
            Over k => { break; },
            Tick k => {},
        }
    }
    print("8 C threads x 4000 signals: wake-ups lost ", io_lost(), ", takes ", takes >= 4000);
    event_close(s);
    event_close(over);
}

// What the loops above left: copies their signals made after they stopped.
fn pause_and_drain() {
    sleep_ms(50);
    loop {
        let m, got = select<Io>(0);
        if !got { break; }
    }
}
