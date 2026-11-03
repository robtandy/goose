// No message lost or stranded (§11.2): a message put while threads wait is
// taken, by one of them or one that was awake, never left with all of its
// takers asleep; a deadline that meets a claim acts on it; spurious
// wake-ups and messages others took first wait on. Eight producers put
// bursts to two global queues and to consumers' inboxes, while four
// consumers sleep in select<In>() and four wake every millisecond in
// select<In>(1). Each round ends only once every message of it is
// acknowledged, so a stranded one fails its round rather than waiting for
// the next burst to wake its taker.
struct A { v: i64 }
struct B { v: i64 }
struct Ack { v: i64 }
struct Round { n: i64, k: i64 }
struct Stop { at: i64 }
enum In { A { a: A }, B { b: B }, S { s: Stop } }

// A message that must come: a minute without one fails rather than hangs.
fn take<T>() -> T {
    let v, got = qget<T>(60000);
    assert(got);
    v
}

thread_fn sleeper() {
    loop {
        match select<In>() {
            A a => { qput(Ack { v: a.a.v }); },
            B b => { qput(Ack { v: b.b.v }); },
            S s => { break; },
        }
    }
}

thread_fn waker() {
    loop {
        let m, got = select<In>(1);
        if !got { continue; }
        match m {
            A a => { qput(Ack { v: a.a.v }); },
            B b => { qput(Ack { v: b.b.v }); },
            S s => { break; },
        }
    }
}

// Each message's value is its producer, round and number: one of each.
thread_fn producer(p: i64, consumers: i64[8]) {
    loop {
        let r = take<Round>();
        if r.n < 0 { break; }
        for k in r.k {
            let v = (p * 100000 + r.n) * 1000 + k;
            match k % 4 {
                0 => { qput(A { v: v }); },
                1 => { qput(B { v: v }); },
                2 => { qput_to(consumers[(p + k) % 8], A { v: v }); },
                _ => { qput_to(consumers[(p + k + 3) % 8], B { v: v }); },
            }
        }
    }
}

fn main() {
    var consumers: i64[8] = [0; 8];
    for i in 8 { consumers[i] = if i < 4 { thread_spawn(sleeper) } else { thread_spawn(waker) }; }
    var producers: i64[>..] = [];
    for p in 8 { producers.push(thread_spawn(producer, p, consumers)); }
    var wrong = 0;
    var total = 0;
    for n in 3000 {
        let k = 1 + n % 24;
        var want = 0;
        for p in 8 {
            qput_to(producers[p], Round { n: n, k: k });
            for j in k { want += (p * 100000 + n) * 1000 + j; }
        }
        var sum = 0;
        for i in 8 * k { sum += take<Ack>().v; }
        if sum != want { wrong++; }
        total += 8 * k;
    }
    let extra, gotextra = qget<Ack>(10);
    print(total, " messages in 3000 rounds, rounds wrong: ", wrong, ", acknowledged twice: ",
          gotextra);
    for p in producers { qput_to(p, Round { n: -1, k: 0 }); }
    for c in consumers { qput_to(c, Stop { at: 0 }); }
    for p in producers { thread_wait(p); }
    for c in consumers { thread_wait(c); }
}
