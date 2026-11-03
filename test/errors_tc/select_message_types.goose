// error: select<Bulk..>: variant Rows receives i64[>..]: select cannot receive a resizable value yet; take it with qget
// error: select<Viewed>: variant S receives i64[:], and queue elements must be flat
// error: cannot pass between threads: it holds an index type
// What select receives is what qget<T> takes (§11.2), but for a resizable
// value, which it does not take yet.
enum Bulk { Rows { r: i64[>..] }, Count { n: i64 } }
enum Viewed { S { s: i64[:] } }
var table: i64[>..] = [];
enum Indexed { At { i: u32 in table } }
fn resizable() { let w = select<Bulk..>(); }
fn viewed() { let w = select<Viewed>(); }
fn indexed() { let w = select<Indexed>(); }
fn main() { resizable(); viewed(); indexed(); }
