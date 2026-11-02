// Handles cross threads (§3.12, §11.2). A handle is flat, so it is a
// thread_fn's parameter, a part of one, a queue message and a part of one,
// and a worker's copy of a global holds what main's held. The C beside this
// program (resource_threads.build) makes each handle from a number and
// gives the number back only for a handle it made, so a worker reading its
// handles' numbers sees the very bits main was handed. A missed qpoll gives
// the zero handle, which names nothing.
struct Token {}
struct Job { n: i64, tok: resource<Token> }
enum Reply { Done { worker: i64, tok: resource<Token> }, Failed { worker: i64 } }

extern fn token_make(n: i64) -> resource<Token>;
extern fn token_number(t: resource<Token>) -> i64;

// Copied to each worker as it is spawned.
var shared: resource<Token>;

thread_fn worker(id: i64, t: resource<Token>, j: Job, ts: resource<Token>[2]) {
    let mine = token_number(t) + token_number(j.tok) + token_number(ts[0]) +
               token_number(ts[1]) + token_number(shared);
    // The message is a Reply, whichever variant it is: a variant's literal
    // alone would be a message of the variant's type.
    let r: Reply = if token_number(t) == id && j.n == id {
        Reply.Done { worker: id, tok: token_make(mine) }
    } else {
        Reply.Failed { worker: id }
    };
    qput(r);
    // A job from main, whoever takes it, answered with its number and its
    // handle's.
    let m = qget<Job>();
    qput(m.n * 1000 + token_number(m.tok));
}

fn main() {
    shared = token_make(5);
    let workers = 4;
    var ids: i64[>..] = [];
    for id in workers {
        let ts: resource<Token>[2] = [token_make(20), token_make(30)];
        ids.push(thread_spawn(worker, id, token_make(id), Job { n: id, tok: token_make(10 + id) }, ts));
    }
    for k in workers { qput(Job { n: k, tok: token_make(100 * k) }); }
    var mine: i64[4] = [-1; 4];
    for k in workers {
        match qget<Reply>() {
            Done d => { mine[d.worker] = token_number(d.tok); },
            Failed f => print("worker ", f.worker, " saw other handles"),
        }
    }
    var jobs = 0;
    for k in workers { jobs += qget<i64>(); }
    var waited = true;
    for id in ids { waited = waited && thread_wait(id); }
    print(mine, " ", jobs, " ", waited);

    // A handle as a message of its own, and a missed poll's zero handle.
    qput(token_make(7));
    let seven = qget<resource<Token>>();
    let missed, got = qpoll<resource<Token>>();
    print(token_number(seven), " ", seven, "; missed: ", token_number(missed), " ", got);
}
