// error: select<Work>: variant Io must hold exactly one field, the message it receives
// error: select<Pair>: variant Two must hold exactly one field, the message it receives
// error: select<Padded>: variant P must hold exactly one field, the message it receives
// error: select<Twice>: variants Data and Retry both receive Batch
// error: select<i64>: select receives into an enum, each of whose variants holds one field
// select<E> (§11.2) receives into an enum each of whose variants holds one
// field, of a distinct type: the variant is the type it receives.
struct Job { n: i64 }
struct Batch { rows: i64[4] }
enum Work { Job { j: Job }, Io }
enum Pair { One { a: i64 }, Two { a: i64, b: i64 } }
enum Padded { P { pad 4 } }
enum Twice { Data { b: Batch }, Retry { r: Batch } }
fn empty() { let w = select<Work>(); }
fn two() { let w = select<Pair>(); }
fn padded() { let w = select<Padded>(); }
fn twice() { let w = select<Twice>(); }
fn notenum() { let w = select<i64>(); }
fn main() { empty(); two(); padded(); twice(); notenum(); }
