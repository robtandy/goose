// Backpressure by credits (§11.2): nothing blocks a put, so a receiver
// grants each sender k batches and returns a credit per k / 2 it takes,
// and a sender without credit waits in select, taking what comes to it
// meanwhile. Then only an ended receiver refuses a put, and an inbox holds
// at most k batches from each sender: four workers repartition their rows
// with windows of 2, every put taken under an inbox limit of 2 per peer.
struct Batch { from: i64, n: i64, rows: i64[8] }
struct Credit { from: i64 }
struct Peers { ids: i64[4] }
struct Total { part: i64, rows: i64, sum: i64 }
enum Traffic { Batch { b: Batch }, Credit { c: Credit } }

let K = 2;

struct Exchange {
    me: i64,
    peers: i64[4],
    credits: i64[4],
    taken: i64[4],
    ends: i64,
    rows: i64,
    sum: i64,
}

fn next() -> Traffic {
    let m, got = select<Traffic>(60000);
    assert(got);
    m
}

// One message: a batch for this partition, or a credit back.
fn receive(x: Exchange&) {
    match next() {
        Batch b => {
            if b.b.n < 0 { x.ends++; }
            for i in b.b.n { x.sum += b.b.rows[i]; }
            if b.b.n > 0 { x.rows += b.b.n; }
            x.taken[b.b.from]++;
            if x.taken[b.b.from] % (K / 2) == 0 {
                qput_to(x.peers[b.b.from], Credit { from: x.me });
            }
        },
        Credit c => { x.credits[c.c.from]++; },
    }
}

// To d, the owner of b's partition.
fn send(x: Exchange&, d: i64, b: const Batch&) {
    while x.credits[d] == 0 { receive(x); }
    let ok = qput_to(x.peers[d], b);
    assert(ok);
    x.credits[d]--;
}

thread_fn worker(me: i64, n: i64) {
    let p = qget<Peers>();
    var x = Exchange { me: me, peers: p.ids, credits: [K; 4], taken: [0; 4], ends: 0, rows: 0,
                       sum: 0 };
    var out: Batch[4] = [Batch { from: me, n: 0, rows: [0; 8] }; 4];
    for r in n {
        let v = me * 100000 + r;
        let d = v % 4;
        if d == me {
            x.rows++;
            x.sum += v;
            continue;
        }
        out[d].rows[out[d].n] = v;
        out[d].n++;
        if out[d].n == 8 {
            send(x, d, out[d]);
            out[d].n = 0;
        }
    }
    for d in 4 {
        if d == me { continue; }
        if out[d].n > 0 { send(x, d, out[d]); }
        // The end, behind the batches in the same queue.
        let end = Batch { from: me, n: -1, rows: [0; 8] };
        send(x, d, end);
    }
    while x.ends < 3 { receive(x); }
    qput(Total { part: me, rows: x.rows, sum: x.sum });
}

fn main() {
    let n = 5000;
    qlimit_inbox<Batch>(K * 3);
    var ids: i64[4] = [0; 4];
    for w in 4 { ids[w] = thread_spawn(worker, w, n); }
    for w in 4 { qput_to(ids[w], Peers { ids: ids }); }
    var rows: i64[4] = [0; 4];
    var sums: i64[4] = [0; 4];
    for w in 4 {
        let t, got = qget<Total>(60000);
        assert(got);
        rows[t.part] = t.rows;
        sums[t.part] = t.sum;
    }
    for id in ids { thread_wait(id); }
    var wrong = 0;
    for part in 4 {
        var want = 0;
        var count = 0;
        for w in 4 {
            for r in n {
                let v = w * 100000 + r;
                if v % 4 == part {
                    want += v;
                    count++;
                }
            }
        }
        if rows[part] != count || sums[part] != want { wrong++; }
    }
    print("4 workers, windows of 2: ", rows[0] + rows[1] + rows[2] + rows[3], " rows, ", wrong,
          " partitions wrong");
}
