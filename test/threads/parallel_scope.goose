// Reusable thread_pool and pool.apply(chunks(...), fn, args...)
// (docs/design/parallel_blocks.md):
// - Worker functions are ordinary top-level `fn`s (callable sequentially or via
//   pool.apply); `thread_fn` is left untouched for standalone actor threads.
// - Supports both uniform chunking `chunks(arr, size)` and prefix-sum offset
//   chunking `chunks(arr, offsets)` (demonstrated with a full parallel Hash
//   Join where both Build and Probe run in parallel via pool.apply).
// - The program ends the pool itself, with `defer pool.close();`: nothing
//   ends it at its scope's exit.

import std;

struct Config {
    scale: i64,
    bias:  i64,
}

fn transform_chunk(chunk: i64[:], chunk_idx: i64, weights: const i64[:], cfg: const Config&) {
    var scratch: i64[>..] = [];
    for w in weights {
        scratch.push(w * cfg.scale);
    }
    for &x, i in chunk {
        let w = scratch[(chunk_idx + i) % scratch.len];
        x = x * w + cfg.bias;
    }
}

fn run_second_pass(pool: thread_pool&, data: i64[:], weights: const i64[:], cfg: const Config&) {
    pool.apply(chunks(data, 4), transform_chunk, weights, cfg);
}

// ---------------------------------------------------------------------------
// Parallel Hash Join (Build ⋈ Probe) using `pool.apply` for BOTH Build & Probe:
//   Phase 0 (Build): `chunks(ht, slots_per_part)` builds P disjoint hash
//                    sub-tables in parallel with zero locks or atomics.
//   Phase 1 (Count): `chunks(counts, 1)` counts matches per probe partition.
//   Phase 2 (Write): `chunks(joined, offsets)` writes matches into each
//                    partition's exact disjoint slice of `joined`.

struct BuildRow {
    key:     i64,
    user_id: i64,
}

struct HashSlot {
    key:      i64,
    user_id:  i64,
    occupied: bool,
}

struct ProbeRow {
    key:   i64,
    cents: i64,
}

struct JoinedRow {
    key:     i64,
    user_id: i64,
    cents:   i64,
}

fn build_ht_partition(
    sub_ht:     HashSlot[:],
    part_idx:   i64,
    build_rows: const BuildRow[:],
    num_parts:  i64,
) {
    let part_mask = num_parts - 1;
    let slot_mask = sub_ht.len - 1;
    for r in build_rows {
        let hash = r.key * 7;
        if (hash & part_mask) == part_idx {
            var h = (hash >> 2) & slot_mask;
            while sub_ht[h].occupied {
                h = (h + 1) & slot_mask;
            }
            sub_ht[h] = HashSlot { key: r.key, user_id: r.user_id, occupied: true };
        }
    }
}

fn count_join_matches(
    count_slot:     i64[:],
    idx:            i64,
    ht:             const HashSlot[:],
    probe:          const ProbeRow[:],
    step:           i64,
    num_parts:      i64,
    slots_per_part: i64,
) {
    let part_mask = num_parts - 1;
    let slot_mask = slots_per_part - 1;
    let lo = idx * step;
    let hi = min(lo + step, probe.len);
    var n = 0;
    for i in lo..hi {
        let p = probe[i];
        let hash = p.key * 7;
        let part = hash & part_mask;
        let sub_ht = ht[part * slots_per_part..(part + 1) * slots_per_part];
        var h = (hash >> 2) & slot_mask;
        while sub_ht[h].occupied {
            if sub_ht[h].key == p.key { n++; }
            h = (h + 1) & slot_mask;
        }
    }
    count_slot[0] = n;
}

fn write_join_matches(
    out_chunk:      JoinedRow[:],
    idx:            i64,
    ht:             const HashSlot[:],
    probe:          const ProbeRow[:],
    step:           i64,
    num_parts:      i64,
    slots_per_part: i64,
) {
    let part_mask = num_parts - 1;
    let slot_mask = slots_per_part - 1;
    let lo = idx * step;
    let hi = min(lo + step, probe.len);
    var pos = 0;
    for i in lo..hi {
        let p = probe[i];
        let hash = p.key * 7;
        let part = hash & part_mask;
        let sub_ht = ht[part * slots_per_part..(part + 1) * slots_per_part];
        var h = (hash >> 2) & slot_mask;
        while sub_ht[h].occupied {
            if sub_ht[h].key == p.key {
                out_chunk[pos] = JoinedRow {
                    key:     p.key,
                    user_id: sub_ht[h].user_id,
                    cents:   p.cents,
                };
                pos++;
            }
            h = (h + 1) & slot_mask;
        }
    }
}

fn main() {
    var pool = thread_pool(4);
    defer pool.close();
    var weights: i64[>..] = [2, 3, 5];
    var cfg = Config { scale: 10, bias: 1 };

    var data: i64[>..] = [];
    for i in 10 { data.push(i + 1); }

    // Pass 1: uniform chunks of 3 (sizes 3, 3, 3, 1).
    pool.apply(chunks(data, 3), transform_chunk, weights, cfg);
    print("after pass 1: ", data);

    // Mutate `weights` and `cfg` between `pool.apply` calls, and reuse `pool`.
    weights.push(7);
    cfg.scale = 2;
    cfg.bias = -1;
    run_second_pass(pool, data, weights, cfg);
    print("after pass 2: ", data);

    // Verify `transform_chunk` is also callable directly as a normal fn:
    var single: i64[2] = [1, 2];
    transform_chunk(single, 0, weights, cfg);
    print("direct call: ", single);

    // Parallel Hash Join demo (both Build and Probe run in parallel!):
    let num_parts = 4;
    let slots_per_part = 4;
    var ht: HashSlot[>..] = [];
    ht.resize(num_parts * slots_per_part, HashSlot { key: 0, user_id: 0, occupied: false });

    let build_rows: BuildRow[3] = [
        BuildRow { key: 10, user_id: 100 },
        BuildRow { key: 20, user_id: 200 },
        BuildRow { key: 30, user_id: 300 },
    ];

    // Join Phase 0 (Parallel Build): each worker builds its own disjoint
    // partition of `ht` (`slots_per_part` slots per partition)!
    pool.apply(chunks(ht, slots_per_part), build_ht_partition, build_rows, num_parts);

    let probe: ProbeRow[6] = [
        ProbeRow { key: 20, cents: 500 },
        ProbeRow { key: 99, cents: 111 },
        ProbeRow { key: 10, cents: 250 },
        ProbeRow { key: 30, cents: 750 },
        ProbeRow { key: 20, cents: 900 },
        ProbeRow { key: 88, cents: 222 },
    ];

    let step = 2;
    let num_morsels = (probe.len + step - 1) / step;
    var counts: i64[>..] = [];
    counts.resize(num_morsels, 0);

    // Join Phase 1 (Parallel Probe Count): count matches per probe morsel in parallel
    pool.apply(chunks(counts, 1), count_join_matches, ht, probe, step, num_parts, slots_per_part);
    print("join counts: ", counts);

    // Prefix sum on main thread
    var offsets: i64[>..] = [0];
    for c in counts {
        offsets.push(offsets[offsets.len - 1] + c);
    }
    var joined: JoinedRow[>..] = [];
    joined.resize(offsets[offsets.len - 1], default<JoinedRow>());

    // Join Phase 2 (Parallel Probe Write): write matches into variable-sized disjoint chunks
    pool.apply(chunks(joined, offsets), write_join_matches, ht, probe, step, num_parts, slots_per_part);
    print("joined rows: ", joined);
}
