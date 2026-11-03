// The typed queues as the runtime has them (spec §11.2), measured: the
// baseline of docs/design/inboxes_select.md, which the queue work it
// plans has to beat. bench/queues.py builds this program and runs each
// configuration in a process of its own:
//
//   queues rt1 <n> <size>             qput then qget on one thread, n times
//   queues rt2 <n> <size>             a message to a waiting worker and its
//                                     answer back, n times
//   queues burst <n> <size>           n qputs, then n qgets, on one thread
//   queues empty <n> <size>           n qpolls of an empty queue, on one thread
//   queues tput <p> <c> <n> <size>    p producers put n messages in all
//                                     while c consumers take them
//   queues drain <c> <n> <size>       n messages queued first, then c
//                                     consumers take them, as a work
//                                     queue's jobs are
//   queues sready <n> <size>          qput then a select of four types, one
//                                     always ready, n times (rt1's select)
//   queues srt2 <n> <size>            rt2 with select on both sides
//   queues ewake <n> 16               a C thread signals an event while its
//                                     owner sleeps in select, n times: the
//                                     time until the owner says it woke
//   queues ewake_qget <n> 16          the same, the owner in qget
//
// <size> is 16 or 32768, the bytes of a message. Each run prints one line of
// name=value fields, with times in nanoseconds. The C beside this program
// (queues.build) is the event modes' signalling thread.
import std;
import os;

struct Small { seq: i64, from: i64 }                     // 16 bytes
struct Large { seq: i64, from: i64, data: i64[4094] }    // 32768 bytes

// The answer of a round trip, a type of its own so that it has a queue of
// its own.
struct Back<M> { m: M }

// select's sources: the message, and three types that never come, so a
// call looks at each before the one that is ready (each site starts after
// the variant it returned last).
struct Never1 { x: i64 }
struct Never2 { x: i64 }
struct Never3 { x: i64 }
enum Four<M> { Ready { m: M }, N1 { n: Never1 }, N2 { n: Never2 }, N3 { n: Never3 } }
enum Two<M> { Msg { m: M }, N1 { n: Never1 } }

// The event modes' C: a thread that signals e n times, each once the owner
// has slept a while after acknowledging the last, timing each signal until
// the owner acknowledges it.
struct Tick { n: i64 }
extern fn qb_events_start(e: resource<event>, n: i64);
extern fn qb_events_ack();
extern fn qb_events_join();
extern fn qb_events_stat(k: i64) -> i64;

// The start signal, a producer's last message, and a consumer's tally.
struct Go { at: i64 }
struct Produced { from: i64, end: i64 }
struct Tally { count: i64, sum: i64, end: i64 }

fn fail(why: const u8[:]) {
    write_stderr(str("queues: ", why, "\n"));
    exit(1);
}

fn number(s: const u8[:]) -> i64 {
    let v, ok = parse_int(s);
    if !ok || v < 0 { fail(str("not a count: ", s)); }
    return v;
}

// --- one thread --------------------------------------------------------------

fn round_trips<M>(n: i64) {
    var m = default<M>();
    var sum = 0;
    let start = clock_ns();
    for i in n {
        m.seq = i;
        qput(m);
        sum += qget<M>().seq;
    }
    let took = clock_ns() - start;
    if sum != n * (n - 1) / 2 { fail("a round trip lost a message"); }
    print("mode=rt1 n=", n, " ns_per_round_trip=", took / max(n, 1));
}

fn burst<M>(n: i64) {
    var m = default<M>();
    let start = clock_ns();
    for i in n {
        m.seq = i;
        qput(m);
    }
    let mid = clock_ns();
    var sum = 0;
    for i in n { sum += qget<M>().seq; }
    let end = clock_ns();
    if sum != n * (n - 1) / 2 { fail("a burst lost a message"); }
    print("mode=burst n=", n, " ns_per_put=", (mid - start) / max(n, 1), " ns_per_get=",
          (end - mid) / max(n, 1));
}

fn empty_polls<M>(n: i64) {
    var got = 0;
    let start = clock_ns();
    for i in n {
        let m, ok = qpoll<M>();
        if ok { got++; }
    }
    let took = clock_ns() - start;
    if got != 0 { fail("an empty queue gave a message"); }
    print("mode=empty n=", n, " ns_per_poll=", took / max(n, 1));
}

fn select_ready<M>(n: i64) {
    var m = default<M>();
    var sum = 0;
    let start = clock_ns();
    for i in n {
        m.seq = i;
        qput(m);
        match select<Four<M>>() {
            Ready r => { sum += r.m.seq; },
            N1 x => {},
            N2 x => {},
            N3 x => {},
        }
    }
    let took = clock_ns() - start;
    if sum != n * (n - 1) / 2 { fail("a select lost a message"); }
    print("mode=sready n=", n, " ns_per_round_trip=", took / max(n, 1));
}

// --- two threads, one message at a time ----------------------------------------

fn echo<M>() {
    loop {
        let m = qget<M>();
        if m.seq < 0 { break; }
        qput(Back<M> { m: m });
    }
}

thread_fn echo_small() { echo<Small>(); }
thread_fn echo_large() { echo<Large>(); }

fn select_echo<M>() {
    loop {
        match select<Two<M>>() {
            Msg x => {
                if x.m.seq < 0 { break; }
                qput(Back<M> { m: x.m });
            },
            N1 x => {},
        }
    }
}

thread_fn select_echo_small() { select_echo<Small>(); }
thread_fn select_echo_large() { select_echo<Large>(); }

// The owner of the event the C thread signals, which says each time it has
// taken the copy, by select or by qget.
thread_fn event_owner(n: i64, by_select: bool) {
    let e = event(Tick { n: 0 });
    qb_events_start(e, n);
    for i in n {
        if by_select {
            match select<Two<Tick>>() {
                Msg x => {},
                N1 x => {},
            }
        } else {
            qget<Tick>();
        }
        qb_events_ack();
    }
    qb_events_join();
    event_close(e);
}

fn event_wake(n: i64, by_select: bool) {
    thread_wait(thread_spawn(event_owner, n, by_select));
    print("mode=", if by_select { "ewake" } else { "ewake_qget" }, " n=", n, " ns_mean=",
          qb_events_stat(3), " ns_p50=", qb_events_stat(0), " ns_p99=", qb_events_stat(1),
          " ns_min=", qb_events_stat(2));
}

fn ping_pong<M, W>(n: i64, by_select: bool) {
    let id = thread_spawn(W);
    var m = default<M>();
    // One round trip first, so that the worker is up and waiting.
    qput(m);
    qget<Back<M>>();
    var times: i64[>..] = [];
    var sum = 0;
    for i in n {
        m.seq = i;
        let start = clock_ns();
        qput(m);
        var b = default<Back<M>>();
        if by_select {
            match select<Two<Back<M>>>() {
                Msg x => { b = x.m; },
                N1 x => {},
            }
        } else {
            b = qget<Back<M>>();
        }
        times.push(clock_ns() - start);
        sum += b.m.seq;
    }
    m.seq = -1;
    qput(m);
    thread_wait(id);
    if sum != n * (n - 1) / 2 { fail("a ping-pong lost a message"); }
    sort(times);
    var total = 0;
    for t in times { total += t; }
    let k = max(times.len, 1);
    print("mode=", if by_select { "srt2" } else { "rt2" }, " n=", n, " ns_mean=", total / k,
          " ns_p50=", times[times.len / 2], " ns_p90=", times[times.len * 9 / 10], " ns_p99=",
          times[times.len * 99 / 100], " ns_min=", times[0]);
}

// --- many threads ------------------------------------------------------------------

fn produce<M>(from: i64, count: i64) {
    qget<Go>();
    var m = default<M>();
    m.from = from;
    for i in count {
        m.seq = i;
        qput(m);
    }
    qput(Produced { from: from, end: clock_ns() });
}

fn consume<M>() {
    qget<Go>();
    var count = 0;
    var sum = 0;
    loop {
        let m = qget<M>();
        if m.seq < 0 { break; }
        count++;
        sum += m.seq;
    }
    qput(Tally { count: count, sum: sum, end: clock_ns() });
}

thread_fn produce_small(from: i64, count: i64) { produce<Small>(from, count); }
thread_fn produce_large(from: i64, count: i64) { produce<Large>(from, count); }
thread_fn consume_small() { consume<Small>(); }
thread_fn consume_large() { consume<Large>(); }

// Takes the consumers' tallies and checks that every message came through
// once: the sum of the counts is n, and of the sequence numbers `sum`.
fn tallies(consumers: i64, n: i64, sum: i64) -> i64 {
    var count = 0;
    var got = 0;
    var end = 0;
    for c in consumers {
        let t = qget<Tally>();
        count += t.count;
        got += t.sum;
        end = max(end, t.end);
    }
    if count != n || got != sum { fail(str("took ", count, " messages of ", n)); }
    return end;
}

// The bytes a message takes, for the throughput in MB/s.
fn bytes(m: Small) -> i64 { 16 }
fn bytes(m: Large) -> i64 { 32768 }

fn report(mode: const u8[:], producers: i64, consumers: i64, n: i64, size: i64, took: i64) {
    let ns = max(took, 1);
    print("mode=", mode, " producers=", producers, " consumers=", consumers, " n=", n, " size=", size,
          " ns=", took, " msgs_per_s=", n * 1000000000 / ns, " mb_per_s=", n * size * 1000 / ns,
          " ns_per_msg=", took / max(n, 1));
}

fn throughput<M, P, C>(producers: i64, consumers: i64, n: i64) {
    var ids: i64[>..] = [];
    var sum = 0;
    for p in producers {
        // n messages in all, as evenly as they go.
        var count = n / producers;
        if p < n % producers { count++; }
        sum += count * (count - 1) / 2;
        ids.push(thread_spawn(P, p, count));
    }
    for c in consumers { ids.push(thread_spawn(C)); }
    let start = clock_ns();
    for i in producers + consumers { qput(Go { at: start }); }
    // Every message is queued once every producer is done; the stop messages
    // go behind them.
    for p in producers { qget<Produced>(); }
    var stop = default<M>();
    stop.seq = -1;
    for c in consumers { qput(stop); }
    let end = tallies(consumers, n, sum);
    for id in ids { thread_wait(id); }
    report("tput", producers, consumers, n, bytes(stop), end - start);
}

fn drain<M, C>(consumers: i64, n: i64) {
    var m = default<M>();
    for i in n {
        m.seq = i;
        qput(m);
    }
    m.seq = -1;
    for c in consumers { qput(m); }
    var ids: i64[>..] = [];
    for c in consumers { ids.push(thread_spawn(C)); }
    let start = clock_ns();
    for c in consumers { qput(Go { at: start }); }
    let end = tallies(consumers, n, n * (n - 1) / 2);
    for id in ids { thread_wait(id); }
    report("drain", 0, consumers, n, bytes(m), end - start);
}

fn main() {
    let a = args();
    guard a.len >= 3 else {
        fail("usage: queues rt1|rt2|burst|empty|sready|srt2|ewake|ewake_qget <n> <size>, tput <p> <c> <n> <size>, drain <c> <n> <size>");
        return;
    }
    let mode = a[1];
    let size = number(a[a.len - 1]);
    guard size == 16 || size == 32768 else {
        fail(str("a message is 16 or 32768 bytes, not ", size));
        return;
    }
    let small = size == 16;
    if mode == "rt1" && a.len == 4 {
        if small { round_trips<Small>(number(a[2])); } else { round_trips<Large>(number(a[2])); }
    } else if mode == "burst" && a.len == 4 {
        if small { burst<Small>(number(a[2])); } else { burst<Large>(number(a[2])); }
    } else if mode == "empty" && a.len == 4 {
        if small { empty_polls<Small>(number(a[2])); } else { empty_polls<Large>(number(a[2])); }
    } else if mode == "rt2" && a.len == 4 {
        if small {
            ping_pong<Small>(number(a[2]), false, echo_small);
        } else {
            ping_pong<Large>(number(a[2]), false, echo_large);
        }
    } else if mode == "srt2" && a.len == 4 {
        if small {
            ping_pong<Small>(number(a[2]), true, select_echo_small);
        } else {
            ping_pong<Large>(number(a[2]), true, select_echo_large);
        }
    } else if mode == "sready" && a.len == 4 {
        if small { select_ready<Small>(number(a[2])); } else { select_ready<Large>(number(a[2])); }
    } else if (mode == "ewake" || mode == "ewake_qget") && a.len == 4 {
        event_wake(number(a[2]), mode == "ewake");
    } else if mode == "tput" && a.len == 6 {
        let p = number(a[2]);
        let c = number(a[3]);
        let n = number(a[4]);
        guard p >= 1 && c >= 1 else {
            fail("tput needs a producer and a consumer");
            return;
        }
        if small {
            throughput<Small>(p, c, n, produce_small, consume_small);
        } else {
            throughput<Large>(p, c, n, produce_large, consume_large);
        }
    } else if mode == "drain" && a.len == 5 {
        let c = number(a[2]);
        let n = number(a[3]);
        guard c >= 1 else {
            fail("drain needs a consumer");
            return;
        }
        if small { drain<Small>(c, n, consume_small); } else { drain<Large>(c, n, consume_large); }
    } else {
        fail(str("unknown mode or wrong arguments: ", mode));
    }
}
