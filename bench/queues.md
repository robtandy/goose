# Typed queues: the baseline

The runtime's typed queues (spec §11.2) as they are at `b7815879`, measured
for [the design of addressed inboxes, `select` and faster
queues](../docs/design/inboxes_select.md), whose §6.1 sets the targets the
queue work (#6) has to meet against them; [phase 1](#phase-1-inboxes-select-and-events),
inboxes, `select` and events (#5), is measured again at the end.
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
  then take them all, as a pool of workers drains the jobs main queued;
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

**Draining a full queue** (`drain`): n messages queued before the consumers start, then taken by all of them, as a pool of workers takes the jobs main queued. Wall time per message, and the total rate.

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

## What the numbers say

The build used clang 20. The figures below are from the tables above, and
the [design note](../docs/design/inboxes_select.md)'s targets (its §6.1) are
set against them.

* **Alone, a queue is cheap.** A put and a take of 16 bytes cost 51 ns on one
  thread, and finding a queue empty 13 ns. Faster queues must not make these
  slower.
* **One lock serializes the takers.** One consumer drains 16-byte messages at
  22.9 M/s; two drain 3.8 M/s between them, and sixteen 3.4 M/s. Adding
  consumers makes the queue six times slower in total, and a take costs a
  worker 16 × 298 ns, about 4.8 µs, when sixteen collide. The lock is held
  for tens of nanoseconds, but a contended `pthread_mutex` puts its waiters
  to sleep, and waking them is what costs.
* **Wake-ups cost microseconds, and every put to a waiting queue makes one.**
  A futex round trip is 11.8 µs, about 6 µs a wake-up, and `rt2` is that
  plus the queue (13.6 µs). One producer feeding four or more consumers
  manages 0.20 to 0.31 M/s, a tenth of what it does into one, because the
  consumers are mostly asleep and `pthread_cond_signal` makes a system call
  on every put. Waking must become rare: only when a thread is actually
  parked, and not when it would be awake within the time a wake-up takes.
* **Large messages are the allocator's.** A 32 KB put into a growing queue
  costs 14.7 µs, against 59 ns for a warm `malloc` and `free`: the queue's
  memory is fresh pages, faulted in one message at a time, and a block freed
  on another thread costs 0.95 µs. Throughput is erratic, 18.5 GB/s at
  2 × 2, 5.8 at 4 × 4 and 38.6 at 8 × 8, each with a tight spread over its
  runs, and the allocator's policies move it (below).
* **The floor is far below.** `fetch_add` stays at about 10 ns per increment
  however many of the 16 cores contend for it, and a compare-exchange loop
  costs about 35 ns, so a queue whose puts and takes are one atomic
  operation each on a shared line can serve tens of millions of messages a
  second. A message between two cores costs about 120 ns each way, and a
  32 KB message needs one copy in and one out, 1.7 to 3.7 µs between a pair.
  What separates today's queues from the floor is the lock, the sleeping on
  it, the wake-up per put, the allocator and two extra copies, none of it the
  per-message bookkeeping that a batched API would save.

## The allocator's share

Each `qput` `malloc`s a node and each `qget` `free`s it, usually on another
thread. The C library allocator's policies then decide much of a 32 KB
queue's speed: with its heap trimming turned off
(`MALLOC_TRIM_THRESHOLD_=4000000000 MALLOC_TOP_PAD_=1073741824`), the same
program, at the same commit and in the same session, gave (GB/s, medians of
three runs):

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

## Phase 1: inboxes, select and events

The runtime of [#5](../docs/design/inboxes_select.md) (its §5 and §7):
thread records, inboxes, a parker per thread, `select` and events, every
take looking at the caller's inbox before the global queue and handing its
message over as a view and a token (`gs_qmsg`). The same program and
harness, with the modes of `select` and of events added; every sample is in
[queues_phase1_results.json](queues_phase1_results.json).

```sh
python3 bench/queues.py --exe build/goose --reps 5 --wait-idle 600 \
    --json bench/queues_phase1_results.json --markdown /tmp/queues.md
python3 bench/queues.py --render bench/queues_phase1_results.json
```

Measured 2026-11-03 16:32 UTC at commit `5796bb9e` (goose v2026.3-310-g31ec3d1c-dirty (runtime f33b70bc0d2b)), `clang -O2`, on Neoverse-N1 (16 CPUs), Linux 7.0.0-1014-aws aarch64. Medians of 5 runs, each a process of its own; 1-minute load average 3.79 before and 3.0 after. Other processes kept at most 3.02 CPUs busy while a configuration ran (median 0.08).

**One message at a time.** `rt1` is `qput` then `qget` on one thread; `burst` is n `qput`s and then n `qget`s on one thread; `rt2` is a message to a worker waiting in `qget<T>()` and its answer back, two wake-ups.

| message | rt1 round trip | burst: qput | burst: qget | rt2 round trip, p50 | rt2 p99 | rt2 min |
|---|---:|---:|---:|---:|---:|---:|
| 16 B | 54 ns | 67 ns | 29 ns | 14.7 us | 19.0 us | 8.6 us |
| 32 KB | 4,092 ns | 15,986 ns | 6,496 ns | 26.0 us | 33.3 us | 25.2 us |

A `qpoll` of an empty queue (`empty`) costs 5 ns.

**Waiting on several sources, and events from C.** `sready` is `rt1` with a `select` of four types for the `qget`, one always ready, so each call looks at the three empty ones first; `srt2` is `rt2` with `select` on both sides; `ewake` times a C thread's `gs_event_signal` until the event's owner, asleep in `select`, has woken and said so, and `ewake_qget` the same with the owner in `qget`.

| | `qget` | `select` |
|---|---:|---:|
| one source ready, 16 B, a put and a take | 54 ns | 68 ns |
| one source ready, 32 KB, a put and a take | 4,092 ns | 5,000 ns |
| woken by a message, 16 B, round trip p50 / p99 | 14.7 us / 19.0 us | 15.2 us / 21.1 us |
| woken by a message, 32 KB, round trip p50 / p99 | 26.0 us / 33.3 us | 30.4 us / 38.3 us |
| woken by an event from C, p50 / p99 / min | 7.2 us / 10.5 us / 6.8 us | 7.2 us / 10.1 us / 6.9 us |

**Draining a full queue** (`drain`): n messages queued before the consumers start, then taken by all of them, as a pool of workers takes the jobs main queued. Wall time per message, and the total rate.

| consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 16 B, per message | 47 ns | 221 ns | 269 ns | 289 ns | 293 ns |
| 16 B, total | 21.3 M/s | 4.5 M/s | 3.7 M/s | 3.5 M/s | 3.4 M/s |
| 32 KB, per message | 3,213 ns | 1,752 ns | 950 ns | 659 ns | 636 ns |
| 32 KB, total | 10.2 GB/s | 18.7 GB/s | 34.5 GB/s | 49.7 GB/s | 51.5 GB/s |

**Throughput, 16-byte messages** (`tput`): millions of messages a second through one queue, producers (rows) putting while consumers (columns) take; in brackets, the wall time per message.

| producers \ consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 1 | 1.91 (524 ns) | 1.50 (664 ns) | 0.35 (2,833 ns) | 0.35 (2,838 ns) | 0.35 (2,856 ns) |
| 2 | 3.59 (278 ns) | 1.94 (516 ns) | 1.28 (781 ns) | 0.60 (1,660 ns) | 0.55 (1,807 ns) |
| 4 | 3.28 (305 ns) | 2.32 (430 ns) | 1.88 (533 ns) | 1.05 (950 ns) | 0.64 (1,558 ns) |
| 8 | 2.81 (355 ns) | 2.04 (489 ns) | 1.79 (559 ns) | 1.69 (592 ns) | 1.21 (823 ns) |
| 16 | 2.59 (386 ns) | 1.84 (543 ns) | 1.82 (550 ns) | 1.81 (552 ns) | 1.68 (595 ns) |

**Throughput, 32 KB messages** (`tput`): GB/s through one queue, producers (rows) putting while consumers (columns) take; in brackets, the wall time per message.

| producers \ consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 1 | 9.90 (3.3 us) | 5.55 (5.9 us) | 5.54 (5.9 us) | 5.50 (6.0 us) | 5.47 (6.0 us) |
| 2 | 6.31 (5.2 us) | 19.57 (1.7 us) | 10.76 (3.0 us) | 10.57 (3.1 us) | 10.39 (3.2 us) |
| 4 | 5.04 (6.5 us) | 11.40 (2.9 us) | 32.11 (1.0 us) | 18.97 (1.7 us) | 15.72 (2.1 us) |
| 8 | 4.61 (7.1 us) | 8.95 (3.7 us) | 18.44 (1.8 us) | 33.66 (1.0 us) | 23.21 (1.4 us) |
| 16 | 3.55 (9.2 us) | 5.33 (6.1 us) | 7.33 (4.5 us) | 9.99 (3.3 us) | 13.97 (2.3 us) |

**Against master, in one session.** The baseline above was measured the
day before, and some of its cells move by more than 10% from one session
to the next (the 32 KB ones above all). So the cells this session puts more
than 10% past the baseline were measured again, against master's runtime
built on the same machine, runs of the two interleaved, five each (medians):

| cell | master | phase 1 | |
|---|---:|---:|---:|
| `burst`, 16 B, a `qget` | 26 ns | 29 ns | +12% |
| `burst`, 32 KB, a `qget` | 6,383 ns | 6,409 ns | 0% |
| `drain`, 16 B, 4 consumers | 236 ns | 220 ns | -7% |
| `tput`, 16 B, 1 × 1 | 458 ns | 434 ns | -5% |
| `tput`, 32 KB, 8 × 8 | 969 ns | 945 ns | -2% |
| `tput`, 32 KB, 16 × 1 | 9,453 ns | 9,296 ns | -2% |
| `rt1`, 16 B | 52 ns | 54 ns | +4% |

## What phase 1's numbers say

* **A take pays for the take interface, and one cell is 12% slower.** A
  `qget` of 16 bytes that finds its message costs 3 ns more than master's:
  the view and the token it writes for the caller to read back (§7 of the
  design), where master returned one pointer, and the check of the
  caller's inbox, which is all that a program using none of the new
  builtins pays. Every other cell is within 10% of master's, most within
  noise, and an empty `qpoll` costs 5 ns, not 13, as a take skips a queue
  whose count says it is empty without taking its lock.
* **Sleeping consumers are woken faster.** Where consumers outnumber
  producers, a put now sets its claim on one sleeping consumer under the
  queue's lock and signals it after letting the lock go, so other puts and
  takes do not wait for the wake-up's system call: `tput` 16 B at 1 × 4
  went from 5.0 to 2.8 us a message, 2 × 4 from 2.6 to 0.8 and 32 KB at
  4 × 4 from 5.6 to 1.0. Waking a thread still makes a system call; phase
  2's parkers make it rare.
* **`select` with a source ready costs the look at the others.** `sready`
  takes the ready message after looking at three empty types, a few loads
  each: 68 ns a put and a take of 16 bytes, against 54 with `qget`. At
  32 KB it copies the message twice, into the enum and out of it where the
  `match` binds the payload by value (spec §3.5), and costs 0.9 us more,
  about the floor's copy of 32 KB in cache; phase 2's copy elisions are
  for that.
* **A wake-up by `select` costs what one by `qget` does.** A round trip
  with `select` on both sides takes 15.2 us at the median against
  `qget`'s 14.7, the 32 KB ones 30.4 against 26.0 for the copies above.
* **An event from C wakes its owner in one wake-up.** From a C thread's
  `gs_event_signal` to the owner, asleep in `select` or in `qget`, saying
  it is awake takes 7.2 us at the median and 10 us at the 99th
  percentile, the same either way: a wake-up's system call and the
  scheduler's, about half of `rt2`'s two (the floor's futex round trip is
  11.8 us).
