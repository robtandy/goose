// error: select<E>() needs exactly one explicit type argument, an enum whose variants hold the messages it receives
// error: select<E>(ms) needs exactly one explicit type argument
// error: qlimit_inbox<T>(n) needs exactly one explicit type argument
// select and qlimit_inbox name their types (§11.2), and a select's wait is
// milliseconds, an i64.
struct Job { n: i64 }
enum Work { J { j: Job } }
fn untyped() { let w = select(); }
fn timedtwo() { let w, got = select<Work, Job>(5); }
fn limit() { qlimit_inbox(4); }
fn main() { untyped(); timedtwo(); limit(); }
