# Typed queues: the baseline

The runtime's typed queues (spec §11.2) as they are at `b7815879`, measured
for [the design of addressed inboxes, `select` and faster
queues](../docs/design/inboxes_select.md), whose §3 reads these numbers and
whose §9.8 sets the targets the queue work (#6) has to meet against them.
`bench/goose/queues.goose` is the program, `bench/queues.py` the harness,
and `bench/queues_floor.c` measures what the machine allows a queue without
one. Every sample is in [queues_results.json](queues_results.json).

## Reproduce

```sh
cmake --build build
python3 bench/queues.py --exe build/goose --reps 5 --floor --wait-idle 900 \
    --json bench/queues_results.json --markdown /tmp/queues.md
python3 bench/queues.py --render bench/queues_results.json    # these tables again
python3 bench/queues.py --exe build/goose --quick              # every mode, in seconds
```

`bench/queues.py` builds the program with `goose build --cc clang -O2` and
runs each configuration in a fresh process, five times, keeping the median.
It first waits for the 1-minute load average to fall below 2, and it
measures the CPU time other processes used while each configuration ran
(`/proc/stat` less its own children's time); a configuration during which
they kept more than half a CPU busy is run again, up to four times. The
modes:

* `rt1`: `qput` then `qget` of one message on one thread, n times;
* `burst`: n `qput`s, then n `qget`s, on one thread;
* `empty`: n `qpoll`s of an empty queue;
* `rt2`: a message to a worker waiting in `qget<T>()`, and its answer back
  on a queue of its own: two wake-ups per round trip;
* `drain`: n messages queued before 1, 2, 4, 8 or 16 consumers start, which
  then take them all, as the workers of a query take the morsels main
  queued;
* `tput`: 1, 2, 4, 8 or 16 producers putting n messages in all while 1, 2,
  4, 8 or 16 consumers take them, every pair of counts. Producers and
  consumers wait for a start message; the time runs from it to the last
  consumer's last message.

Messages are 16 bytes (`struct Small { seq: i64, from: i64 }`) or 32 KB
(`struct Large { seq: i64, from: i64, data: i64[4094] }`), and every run
checks that each message came through exactly once.

## Results

Measured 2026-11-01 15:59 UTC at commit `b7815879` (goose v2026.3-257-gb7815879 (runtime 3901ec457ba9)), `clang -O2`, on Neoverse-N1 (16 CPUs), Linux 7.0.0-1014-aws aarch64. Medians of 5 runs, each a process of its own; 1-minute load average 0.43 before and 3.47 after. Other processes kept at most 0.48 CPUs busy while a configuration ran (median 0.17).

**One message at a time.** `rt1` is `qput` then `qget` on one thread; `burst` is n `qput`s and then n `qget`s on one thread; `rt2` is a message to a worker waiting in `qget<T>()` and its answer back, two wake-ups.

| message | rt1 round trip | burst: qput | burst: qget | rt2 round trip, p50 | rt2 p99 | rt2 min |
|---|---:|---:|---:|---:|---:|---:|
| 16 B | 51 ns | 63 ns | 26 ns | 13.6 us | 17.7 us | 7.9 us |
| 32 KB | 4,091 ns | 14,679 ns | 5,694 ns | 25.8 us | 32.7 us | 25.3 us |

A `qpoll` of an empty queue (`empty`) costs 13 ns.

**Draining a full queue** (`drain`): n messages queued before the consumers start, then taken by all of them, as the engine's workers take the morsels main queued. Wall time per message, and the total rate.

| consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 16 B, per message | 43 ns | 266 ns | 226 ns | 282 ns | 298 ns |
| 16 B, total | 22.9 M/s | 3.8 M/s | 4.4 M/s | 3.5 M/s | 3.4 M/s |
| 32 KB, per message | 3,237 ns | 1,787 ns | 975 ns | 658 ns | 616 ns |
| 32 KB, total | 10.1 GB/s | 18.3 GB/s | 33.6 GB/s | 49.8 GB/s | 53.1 GB/s |

**Throughput, 16-byte messages** (`tput`): millions of messages a second through one queue, producers (rows) putting while consumers (columns) take; in brackets, the wall time per message.

| producers \ consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 1 | 2.14 (468 ns) | 1.25 (797 ns) | 0.20 (5,023 ns) | 0.26 (3,812 ns) | 0.31 (3,258 ns) |
| 2 | 3.56 (280 ns) | 2.03 (493 ns) | 0.38 (2,609 ns) | 0.30 (3,312 ns) | 0.40 (2,499 ns) |
| 4 | 3.34 (299 ns) | 1.93 (518 ns) | 1.79 (558 ns) | 0.29 (3,442 ns) | 0.43 (2,322 ns) |
| 8 | 2.94 (340 ns) | 1.99 (501 ns) | 1.93 (519 ns) | 1.69 (593 ns) | 0.40 (2,531 ns) |
| 16 | 2.74 (364 ns) | 1.78 (560 ns) | 1.82 (548 ns) | 1.66 (602 ns) | 1.58 (634 ns) |

**Throughput, 32 KB messages** (`tput`): GB/s through one queue, producers (rows) putting while consumers (columns) take; in brackets, the wall time per message.

| producers \ consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 1 | 9.80 (3.3 us) | 5.19 (6.3 us) | 5.47 (6.0 us) | 5.58 (5.9 us) | 5.57 (5.9 us) |
| 2 | 6.29 (5.2 us) | 18.50 (1.8 us) | 5.62 (5.8 us) | 7.69 (4.3 us) | 8.82 (3.7 us) |
| 4 | 5.39 (6.1 us) | 11.41 (2.9 us) | 5.84 (5.6 us) | 7.64 (4.3 us) | 10.81 (3.0 us) |
| 8 | 5.01 (6.5 us) | 9.30 (3.5 us) | 18.34 (1.8 us) | 38.63 (0.8 us) | 10.66 (3.1 us) |
| 16 | 3.92 (8.4 us) | 5.77 (5.7 us) | 7.63 (4.3 us) | 8.59 (3.8 us) | 11.33 (2.9 us) |

**What the machine allows** (`bench/queues_floor.c`, no queue): the costs a queue is made of, medians.

| one shared counter, threads | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| `fetch_add`, ns per increment | 5.6 ns | 9.1 ns | 9.4 ns | 9.6 ns | 9.7 ns |
| compare-exchange loop | 8.3 ns | 20.2 ns | 27.8 ns | 35.8 ns | 34.7 ns |

| between two threads, or on one | |
|---|---:|
| a turn passed back and forth by spinning on a shared word, round trip | 240 ns |
| the same, each side sleeping in `futex_wait` until woken, round trip | 11,835 ns |
| `malloc` + `free` of 16 B on one thread | 18.7 ns |
| `malloc` of 16 B on one thread, `free` on another | 196 ns |
| `malloc` + `free` of 32 KB on one thread | 59.1 ns |
| `malloc` of 32 KB on one thread, `free` on another | 945 ns |
| `memcpy` of 32 KB in cache | 827 ns |
| `memcpy` of 32 KB streamed from memory | 1,845 ns |

## The allocator's share

Each `qput` `malloc`s a node and each `qget` `free`s it, usually on another
thread. glibc's policies then decide much of a 32 KB queue's speed: with its
heap trimming turned off (`MALLOC_TRIM_THRESHOLD_=4000000000
MALLOC_TOP_PAD_=1073741824`), the same program, at the same commit and in the
same session, gave (GB/s, medians of three runs):

| producers × consumers | default | trimming off |
|---|---:|---:|
| 16 × 1 | 3.7 | 8.1 |
| 8 × 8 | 35.7 | 7.2 |
| 4 × 4 | 5.6 | 5.4 |
| 2 × 2 | 18.1 | 19.0 |

```sh
MALLOC_TRIM_THRESHOLD_=4000000000 MALLOC_TOP_PAD_=1073741824 \
    build/bench/queues/queues tput 16 1 20000 32768
```

Neither setting is the better one: the cell that doubles with one halves
with the other. That, the 14.7 µs `burst` put of fresh pages against the
59 ns of a warm `malloc` and `free`, and the 0.95 µs of a 32 KB block freed
on another thread are why the design takes the allocator out of the queue.
