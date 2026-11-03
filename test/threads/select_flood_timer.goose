// An event loop's timer under a flood (§11.2): select<E>(ms) returns a
// waiting message whatever its timeout, so a loop that waits for the time
// to its next timer checks the timer every turn. Four flooders keep the
// loop's inbox full for a second; its 10 ms timer must still fire 80 times
// or more, re-armed from when it fires, while the loop takes thousands of
// messages.
import os;

struct Item { n: i64 }
struct Stop { at: i64 }
struct Ticks { ticks: i64, items: i64 }
enum In { I { i: Item }, S { s: Stop } }

thread_fn flooder(target: i64) {
    var n = 0;
    loop {
        // A full inbox stays full while a refused flooder waits a little.
        if qput_to(target, Item { n: n }) { n++; } else { sleep_ms(1); }
        let s, stop = qpoll<Stop>();
        if stop { break; }
    }
}

thread_fn timer_loop() {
    let tick = 10000000;
    let start = clock_ns();
    var next = start + tick;
    var ticks = 0;
    var items = 0;
    loop {
        let now = clock_ns();
        if now >= next {
            ticks++;
            next = now + tick;
        }
        if now - start >= 1000000000 { break; }
        let m, got = select<In>((next - now + 999999) / 1000000);
        if got {
            match m {
                I i => { items++; },
                S s => {},
            }
        }
    }
    qput(Ticks { ticks: ticks, items: items });
}

fn main() {
    qlimit_inbox<Item>(1000);
    let t = thread_spawn(timer_loop);
    var fs: i64[>..] = [];
    for i in 4 { fs.push(thread_spawn(flooder, t)); }
    let r, got = qget<Ticks>(60000);
    assert(got);
    for f in fs { qput(Stop { at: 0 }); }
    for f in fs { thread_wait(f); }
    thread_wait(t);
    print("10 ms timer under a flood: ", r.ticks >= 80, " (", r.items >= 1000, " messages taken)");
}
