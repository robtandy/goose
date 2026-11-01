// The loops of the radix-partitioned hash join in
// docs/design/shared_memory.md, section 6, over `const` slices standing in
// for views. A view of a mapped file or of a frozen region is exactly such a
// slice, so these loops are `checkfree` over views if they are `checkfree`
// here: today's compiler accepts all three at -O0, -O1 and -O2.
//
//     goose run bench/shared_memory/join_loops.goose
//
// prints the matches and the payload sum, the same from the partitioned
// tables as from a nested loop over the rows.
import std;

struct Row { key: i64, payload: i64 }
// A run of one partition's rows in a worker's output.
struct Run { part: i64, start: i64, count: i64 }
// A table: its first entries are the chain heads, the rest its rows, linked
// by self-relative references within the one array.
struct Entry { key: i64, payload: i64, next: Entry&<u32>? }
struct Result { matches: i64, sum: i64 }

// A multiplicative hash, kept non-negative so that `h % n` is an index.
checkfree inline fn mix(k: i64) -> i64 { ((k as! u64) * 0x9E3779B97F4A7C15 >> 1) as! i64 }

// Phase 1: a full (or the last) buffer of partition p, appended as a run.
checkfree fn flush(buf: Row[..64]&, p: i64, rows: Row[>..]&, runs: Run[>..]&) {
    runs.push(Run { part: p, start: rows.len, count: buf.len });
    rows.append(buf);
    buf.clear();
}

// Phase 1: one morsel's rows, from two views of the same rows, into the
// partitions' write-combining buffers.
checkfree fn scatter(keys: const i64[:], pays: const i64[:], bufs: Row[..64][>..]&,
                     rows: Row[>..]&, runs: Run[>..]&) {
    assert(pays.len == keys.len);
    for i in keys.len {
        let h = mix(keys[i]);
        let p = h % bufs.len;
        bufs[p].push(Row { key: keys[i], payload: pays[i] });
        if bufs[p].len == bufs[p].cap { flush(bufs[p], p, rows, runs); }
    }
}

// Phase 2: rows of one partition into its table, whose first `heads`
// entries are the chain heads.
checkfree fn insert(t: Entry[>..]&, heads: i64, rows: const Row[:]) {
    assert(heads > 0 && heads <= t.len);
    for r in rows {
        let h = mix(r.key) >> 7;
        let b = h % heads;
        let e .= t.push(Entry { key: r.key, payload: r.payload, next: t[b].next });
        t[b].next .= e;
    }
}

// Phase 3: every probe key against its partition's table. The links in a
// table's heads reach its rows past the cut.
checkfree fn probe(tables: const (const Entry[:])[:], keys: const i64[:], res: Result&) {
    for k in keys {
        let h = mix(k);
        let t = tables[h % tables.len];
        let b = h >> 7;
        var e = t[b % t.len].next;
        while e {
            if e.key == k {
                res.matches += 1;
                res.sum += e.payload;
            }
            e .= e.next;
        }
    }
}

// Phase 2's task without the views: partition `part` of `rows`, by `runs`.
fn build_table(t: Entry[>..]&, part: i64, rows: const Row[:], runs: const Run[:]) -> i64 {
    var n = 0;
    for r in runs { if r.part == part { n += r.count; } }
    let heads = next_pow2(max(n, 1));
    for i in heads { t.push(Entry { key: 0, payload: 0, next: null }); }
    for r in runs { if r.part == part { insert(t, heads, rows[r.start..r.start + r.count]); } }
    return heads;
}

fn main() {
    let parts = 4;
    var keys: i64[>..] = [];
    var pays: i64[>..] = [];
    for i in 5000 {
        keys.push(i * 7 % 1300);
        pays.push(i);
    }
    // Phase 1, as one worker with one morsel.
    var bufs: Row[..64][>..] = [];
    for p in parts { bufs.push([]); }
    var rows: Row[>..] = [];
    var runs: Run[>..] = [];
    scatter(keys, pays, bufs, rows, runs);
    for p in bufs.len { if bufs[p].len > 0 { flush(bufs[p], p, rows, runs); } }
    // Phase 2: a table per partition.
    var t0: Entry[>..] = [];
    var t1: Entry[>..] = [];
    var t2: Entry[>..] = [];
    var t3: Entry[>..] = [];
    let h0 = build_table(t0, 0, rows, runs);
    let h1 = build_table(t1, 1, rows, runs);
    let h2 = build_table(t2, 2, rows, runs);
    let h3 = build_table(t3, 3, rows, runs);
    // Phase 3.
    let tables: (const Entry[:])[4] = [t0[..h0], t1[..h1], t2[..h2], t3[..h3]];
    var probes: i64[>..] = [];
    for i in 3000 { probes.push(i); }
    var got = Result { matches: 0, sum: 0 };
    probe(tables, probes, got);
    var want = Result { matches: 0, sum: 0 };
    for k in probes {
        for i in keys.len {
            if keys[i] == k {
                want.matches += 1;
                want.sum += pays[i];
            }
        }
    }
    print(got.matches, " matches, payloads summing to ", got.sum);
    if got != want { abort("the partitioned tables disagree with the nested loop"); }
}
