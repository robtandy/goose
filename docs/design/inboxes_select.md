# Addressed inboxes, `select`, and faster typed queues

<details>
<summary>Table of contents</summary>

- [1. Decisions](#1-decisions)
- [2. What there is today](#2-what-there-is-today)
- [3. Today's queues, measured](#3-todays-queues-measured)
- [4. Addressed delivery](#4-addressed-delivery)
- [5. `select`](#5-select)
- [6. Events from C](#6-events-from-c)
- [7. Coroutines](#7-coroutines)
- [8. The engine's three uses](#8-the-engines-three-uses)
- [9. Faster queues](#9-faster-queues)
- [10. The generated C](#10-the-generated-c)
- [11. The compiler's pieces](#11-the-compilers-pieces)
- [12. Alternatives considered](#12-alternatives-considered)
- [13. Testing](#13-testing)
- [14. Documentation](#14-documentation)
- [15. The plan](#15-the-plan)
- [16. Open questions](#16-open-questions)
- [References](#references)

</details>

Goose threads share no mutable memory and talk through typed queues, one
per flat type (spec §11.2). Any thread takes the next message of a type,
and a thread waits on one queue at a time. This note proposes three
additions that an engine of share-nothing workers needs, and that Goose's
planned coroutines need underneath them: **addressed delivery**, a message
to one particular thread; **`select`**, a wait on several sources at once,
including events that C signals when an I/O completes; and **faster
queues**, with no `malloc` and no single lock per message. The consumer
that motivates it is more-fast-db, an analytical query engine written in
Goose (its `docs/architecture.md` and `docs/sched.md`), but nothing here is
specific to it. Everything §11.2 promises stays as it is. Written against
the tree at `b7815879`. Not implemented: issue #5 builds phase 1 (§15),
addressed delivery and `select`; #6 builds phase 2, the queues' speed.

## 1. Decisions

* **Still no shared mutable memory.** Every new builtin moves copies of
  flat values between threads, as `qput` does, or names a thread by its id;
  none adds a shared object, an atomic, a lock or an unsafe operation to
  the language. The locks and atomics are the runtime's, as today's
  mutex is.
* **Per-thread inboxes, addressed by thread id.** Every thread has an
  inbox for every queue type, beside the type's global queue.
  `qput_to(id, v) -> bool` puts `v` in thread `id`'s inbox, and the existing
  `qget<T>()`, `qpoll<T>()` and `qget<T>(ms)` take from the caller's inbox
  first and then from the global queue. `thread_id() -> i64` names the
  calling thread; main's id is -1. No channel objects: the address is the
  id `thread_spawn` already returns, and a stream is told apart by its
  type, as today (§4.1).
* **Ids.** `qput_to` to a worker that has ended, by returning or by an
  abort while contained, returns `false` and queues nothing, as a put to a
  full queue does; to an id that was never issued it aborts, as
  `thread_wait` does. A worker's inboxes close, and the messages left in
  them are discarded, before `thread_wait` for it returns (§4.3, §4.6).
* **Limits per queue.** `qlimit<T>(n)` bounds each queue of `T` on its
  own: the global queue and every thread's inbox. A put to a full inbox is
  refused at once, as today; nothing blocks. Backpressure between workers
  is a protocol of credits, which `select` makes cheap (§4.4, §8.2).
* **Order.** Each queue, an inbox or a global queue, stays first in, first
  out, as today's are: one thread's puts to it are taken in the order they
  were made, and a put that returned before another started is taken
  before it (§4.5).
* **`thread_watch(id, v)`** puts a copy of `v` in the caller's inbox when
  worker `id` ends (at once if it has). With it a thread learns of a
  worker's end, or its abort, without blocking in `thread_wait`, and can
  wait for that and for messages together (§4.6).
* **`select<E>()` and `select<E>(ms) -> E, bool`** wait for the next
  message of any of several types. `E` is an enum each of whose variants
  holds one field; a variant's field type is a type to receive, and
  `select` returns the message wrapped in its variant. The timed form
  behaves as `qget<T>(ms)` does. Sources are checked in a rotation kept per
  call site, so a type with messages is taken within as many calls as `E`
  has variants; `select` never returns without a message except at its
  deadline (§5).
* **Events from C are messages.** `event(v) -> i64` makes an event that
  belongs to the calling thread. C calls `gs_event_signal(e)` from any
  thread, Goose's or not, and a copy of `v` arrives in the owner's inbox,
  where `qget` and `select` find it like any other message; signals that
  come while it waits there are merged into it. The runtime therefore wakes
  a thread only by giving it a message, and `select` needs no source but
  typed queues and a deadline (§6).
* **Coroutines.** coroutines.md makes `select` and channels libraries over
  coroutines. The one runtime primitive such a library needs is the
  thread-level wait: block this thread until a message of one of these
  types arrives or a deadline passes, take it, and say which. That is
  `select<E>(ms)`. Everything inside one thread stays in the library, and
  flat frames travel between workers with `qput_to` (§7).
* **Faster queues, without new surface.** Phase 2 changes the runtime, and
  removes two copies from the generated code: each queue becomes a ring of
  64-byte slots in recycled segments, claimed with tickets, with messages
  of up to 48 bytes in the slot and larger ones in chunks that the sending
  thread fills and that are recycled when their last message is taken.
  Waiting threads spin briefly, then park on a word of their own; a put
  wakes a thread only if one is parked. A value is copied once in and once
  out (§9). No batched API: §3 shows the per-message cost is not where the
  time goes.
* **Measured first.** `bench/queues.py` measures today's queues (round
  trips, a full queue drained by 1 to 16 consumers, and 1 to 16 producers
  against 1 to 16 consumers with 16-byte and 32 KB messages), and what the
  machine allows (§3). Those numbers are the baseline #6 has to beat, and
  §9.8 sets its targets.

## 2. What there is today

### 2.1 The language

§11.2 gives every flat type one queue. `qput(v) -> bool` copies `v` in and
never blocks; it returns `false`, queueing nothing, when the queue holds its
limit, which `qlimit<T>(n)` sets (a queue has none until then). `qget<T>()`
blocks for the next value, `qpoll<T>() -> T, bool` does not, and
`qget<T>(ms) -> T, bool` waits at most `ms` milliseconds; a miss gives `T`'s
zero value and `false`. Workers are `thread_fn`s started by
`thread_spawn(worker, args…)`, which returns an id that increases
monotonically and is never reused; `thread_wait(id) -> bool` blocks until
the worker has ended and its storage is released, and answers `false` for
a contained worker that aborted. Queued messages belong to their queues and
outlive their senders. There is no way to send to one thread, to wait for
two things, or to wake a thread from C.

### 2.2 The runtime

`src/runtime/runtime_threads.h` holds a queue as a `gs_qstate`: a linked
list of nodes, a count, a limit, a mutex and a condition variable. The
compiler emits one `gs_queue` global per element type and `gs_qinit`s them
all in `gs_program_init`.

* `gs_qput` `malloc`s a node of the message's size, copies the message
  into it, then takes the mutex to check the limit and link the node, and
  signals the condition variable, which is a `futex` system call whenever a
  receiver is waiting. A refused put frees the node.
* `gs_qget` takes the same mutex, waits on the condition variable while the
  list is empty, and unlinks the head. `gs_qwait` is the timed form, on the
  monotonic clock, and `gs_qpoll` is `gs_qwait` with no time.
* The generated code copies the value out of the node and `free`s it
  (`codegen_builtins.h`, `B_QGET`). For a fixed-size message it also
  copies through a temporary on each side: `qput(m)` copies `m` to a
  temporary that `gs_qput` copies into the node, and `let m = qget<M>()`
  copies the node into a temporary that is then copied into `m`. A 32 KB
  message is copied four times where the semantics need two.

The worker registry is a list of `gs_thread` records under
`gs_threads_mutex`; a record is `malloc`ed at spawn and freed when the
worker ends. `gs_current_thread_id` is thread-local, -1 on main.

### 2.3 What the engine does with it

more-fast-db's run protocol (`docs/architecture.md`) puts one `Morsel` per
row group on the global morsel queue and one stop message per worker
behind them; 16 contained workers take morsels until they take a stop, and
each sends one `WorkerReport<P>` on the report queue. Main waits for every
worker with `thread_wait` before it takes any report, because a worker that
aborted sends none and a blocking `qget` would hang. Its `docs/sched.md`
measured a round trip of 50 ns on one thread and 14 µs between two, and a
take that costs a worker about 5 µs when 16 workers take at once; its
`docs/pipeline.md` measured 1.5 µs per morsel taken in a Q1 run, and 40 ms
between the last report and the end of the run, spent in threads ending,
which main has to wait out before it can use a report.

The engine's next steps need what the queues do not have: partitioned
exchanges, which send batches of 2048-row vectors (16 to 50 KB each) to the
worker that owns a partition, at hundreds of MB/s to GB/s across 16
workers; control messages to one worker; and wake-ups when an I/O
completes.

## 3. Today's queues, measured

### 3.1 How

`bench/goose/queues.goose` is one program with a mode per measurement, and
`bench/queues.py` builds it with `goose build --cc clang -O2` and runs each
configuration in a process of its own, five times, keeping the median. It
waits for the machine to be idle and measures the CPU time other processes
used while each configuration ran; one that was disturbed by more than half
a CPU is run again. `bench/queues_floor.c` measures, in C and without a
queue, the costs a queue is built from. The committed session is
`bench/queues_results.json`, whose tables `bench/queues.md` shows:

```sh
cmake --build build
python3 bench/queues.py --exe build/goose --reps 5 --floor --wait-idle 900 \
    --json bench/queues_results.json --markdown /tmp/queues.md
python3 bench/queues.py --render bench/queues_results.json    # the tables again
```

The modes: `rt1` puts a message and takes it back on one thread; `burst`
puts n and then takes n; `empty` polls an empty queue; `rt2` sends a
message to a worker waiting in `qget` and waits for its answer, two
wake-ups; `drain` queues n messages before 1 to 16 consumers start and
take them all, as the engine's workers take the morsels main queued; and
`tput` runs 1, 2, 4, 8 or 16 producers putting n messages in all while 1,
2, 4, 8 or 16 consumers take them, every pair. Messages are 16 bytes
(`struct { seq: i64, from: i64 }`) or 32 KB (the same with an
`i64[4094]`).

### 3.2 The numbers

Measured 2026-11-01 on the workspace, 16 Neoverse-N1 cores (AWS, Linux
7.0, aarch64), clang 20 at `-O2`, at `b7815879`; other processes used at
most 0.48 of a CPU while a configuration ran.

**One message at a time.**

| message | `rt1` round trip | `burst`: `qput` | `burst`: `qget` | `rt2` round trip, median | `rt2` p99 |
|---|---:|---:|---:|---:|---:|
| 16 B | 51 ns | 63 ns | 26 ns | 13.6 µs | 17.7 µs |
| 32 KB | 4.1 µs | 14.7 µs | 5.7 µs | 25.8 µs | 32.7 µs |

A `qpoll` of an empty queue costs 13 ns.

**A full queue drained** (`drain`): wall time per message, and the rate
over all consumers.

| consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 16 B, per message | 43 ns | 266 ns | 226 ns | 282 ns | 298 ns |
| 16 B, total | 22.9 M/s | 3.8 M/s | 4.4 M/s | 3.5 M/s | 3.4 M/s |
| 32 KB, per message | 3.24 µs | 1.79 µs | 0.98 µs | 0.66 µs | 0.62 µs |
| 32 KB, total | 10.1 GB/s | 18.3 GB/s | 33.6 GB/s | 49.8 GB/s | 53.1 GB/s |

**16-byte messages through one queue** (`tput`), millions a second,
producers in rows and consumers in columns:

| producers \ consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 1 | 2.14 | 1.25 | 0.20 | 0.26 | 0.31 |
| 2 | 3.56 | 2.03 | 0.38 | 0.30 | 0.40 |
| 4 | 3.34 | 1.93 | 1.79 | 0.29 | 0.43 |
| 8 | 2.94 | 1.99 | 1.93 | 1.69 | 0.40 |
| 16 | 2.74 | 1.78 | 1.82 | 1.66 | 1.58 |

**32 KB messages through one queue** (`tput`), GB/s:

| producers \ consumers | 1 | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| 1 | 9.80 | 5.19 | 5.47 | 5.58 | 5.57 |
| 2 | 6.29 | 18.50 | 5.62 | 7.69 | 8.82 |
| 4 | 5.39 | 11.41 | 5.84 | 7.64 | 10.81 |
| 8 | 5.01 | 9.30 | 18.34 | 38.63 | 10.66 |
| 16 | 3.92 | 5.77 | 7.63 | 8.59 | 11.33 |

### 3.3 What the machine allows

`bench/queues_floor.c`, the same session:

| | |
|---|---:|
| `fetch_add` on one shared counter, ns per increment, 1 / 2 / 16 threads | 5.6 / 9.1 / 9.7 ns |
| a compare-exchange loop on it, 1 / 2 / 16 threads | 8.3 / 20.2 / 34.7 ns |
| a turn passed between two threads spinning on a shared word, round trip | 240 ns |
| the same with each side asleep in `futex_wait` until woken, round trip | 11.8 µs |
| `malloc` + `free` of 16 B on one thread / freed on another | 18.7 / 196 ns |
| `malloc` + `free` of 32 KB on one thread / freed on another | 59 / 945 ns |
| `memcpy` of 32 KB, in cache / streamed from memory | 0.83 / 1.85 µs |

### 3.4 What the numbers say

* **Alone, a queue is cheap.** 51 ns for a put and a take of 16 bytes,
  13 ns to find a queue empty. Phase 2 must not make these slower.
* **One lock serializes the takers.** One consumer drains 16-byte messages
  at 22.9 M/s; two drain 3.8 M/s between them and 16 drain 3.4 M/s. Adding
  consumers makes the queue six times slower in total, and a take costs a
  worker 16 × 298 ns ≈ 4.8 µs when 16 collide, which is the 5 µs
  more-fast-db measured. The lock is held for tens of nanoseconds, but a
  contended `pthread_mutex` puts its waiters to sleep, and waking them is
  what costs.
* **Wake-ups cost microseconds, and every put to a waiting queue makes
  one.** On this machine a futex round trip is 11.8 µs, about 6 µs a
  wake-up, and `rt2` is that plus the queue (13.6 µs). One producer feeding
  four or more consumers manages 0.20 to 0.31 M/s, a tenth of what it does
  into one consumer, because consumers are mostly asleep and
  `pthread_cond_signal` makes a system call on every put. Waking must
  become rare: only when a thread is actually parked, and not at all when
  it would be awake within the time a wake-up takes.
* **Large messages are the allocator's.** A 32 KB put into a growing
  queue costs 14.7 µs, against 59 ns for a warm `malloc` and `free`: the
  queue's memory is fresh pages, faulted in one message at a time. A block
  freed on another thread costs 0.95 µs. Throughput is erratic: 18.5 GB/s
  at 2 × 2, 5.8 at 4 × 4, 38.6 at 8 × 8, each with a tight spread over its
  runs, and glibc's policies move it: with heap trimming turned off, 16 × 1
  goes from 3.7 to 8.1 GB/s and 8 × 8 from 35.7 to 7.2 GB/s
  (`bench/queues.md`). The allocator decides, not the queue.
* **The floor is far below.** `fetch_add` stays at about 10 ns per
  increment however many of the 16 cores contend for it, so a queue claimed
  by tickets can serve tens of millions of messages a second; a
  compare-exchange loop costs three times that. A message between two
  cores costs about 120 ns each way. A 32 KB message needs one copy in and
  one out, 1.7 to 3.7 µs between one pair. What separates today's queues
  from the floor is the lock, the sleeping on it, the wake-up per put, the
  allocator and two extra copies; none of it is the per-message
  bookkeeping a batched API would save.

## 4. Addressed delivery

### 4.1 Inboxes, not channels

The issue's two candidates are per-thread inboxes, addressed by thread id,
and channel handles, which one thread creates and passes to others.

**Inboxes** (chosen). Every thread has, for every queue type `T`, an inbox
beside `T`'s global queue: a queue that only that thread takes from. The
address is the id `thread_spawn` returns, which the program already has,
passes around and waits on, and which is already never reused, so a stale
address cannot reach a newer thread. An inbox lives exactly as long as its
thread, so it needs no lifetime rule, no handle and no table the program
manages. It keeps §11.2's model, a statically typed coordination space in
which a queue is chosen by type, and adds one coordinate: a type and,
optionally, a thread. Two streams to one thread are two types, as two
streams between any threads are today.

**Channel handles** would add a kind of value: a flat `chan<T>` naming a
queue, created by a thread and copied into messages and spawn arguments.
Each question inboxes answer by construction would need an answer of its
own. Who may take from a channel: only its creator (then it is an inbox
with a second name), or anyone holding it (then it is a global queue with a
name, and its taking threads must be told apart again). When it is freed:
with its creator (then every copy is a dangling handle, which needs a
generation check: the never-reused id inboxes already have), or explicitly
(then a program can free a channel others still hold). The language has no
opaque value type for the handle (`resource<U>` in
`owning_dynamic_data.md` is a proposal), so it would be an integer that a
program can make up. What channels add over inboxes is several queues of
one type per thread, which a wrapper type gives (`struct ToJoin { b:
Batch }`), and queues that are not tied to a thread, which the global
queues are. The engine needs neither.

**Tags or patterns** (Linda's `in` with a template, Erlang's selective
`receive`) would let a receive pick a message by its contents. A receive
then scans its queue, and a message no pattern matches stays forever: a
cost per message that grows with what is queued, and a leak. Types do the
selecting at compile time instead, and §5 waits on several types.

### 4.2 The builtins

* `thread_id() -> i64`: the calling thread's id, the one `thread_spawn`
  returned for it, and -1 on main's thread.
* `qput_to(id, v) -> bool`: puts `v` in thread `id`'s inbox for `v`'s type.
  `v` is flat, as for `qput`. It returns `true` once `v` is queued, and
  `false` at once, queueing nothing, when that inbox holds its limit or
  thread `id` has ended. It never blocks. `qput_to(id, v);` as a statement
  drops the result, as `qput(v);` does.
* `qget<T>()`, `qpoll<T>()`, `qget<T>(ms)` keep their signatures and
  results. They take the oldest message in the caller's inbox for `T`, or,
  when that is empty, the oldest in `T`'s global queue; a blocking `qget`
  wakes for either. A program that addresses nothing sees exactly what it
  sees today.

An inbox exists from the moment its thread's id is issued: `thread_spawn`
makes the worker's inboxes before the worker starts, so the spawner may
`qput_to` it at once and the worker finds those messages at its first take.
A thread may put in its own inbox. Any thread may address any thread whose
id it has, including a sibling's or its parent's.

### 4.3 Ids: main, ended workers, ids never issued

| id | `qput_to(id, v)` | `thread_watch(id, v)` (§4.6) | `thread_wait(id)` (today) |
|---|---|---|---|
| -1, main | main's inbox | aborts: main is never waited for | aborts |
| a running worker | its inbox | watches it | waits |
| a worker that ended: it returned, or aborted while contained | `false` | `v` arrives at once | returns at once |
| the caller's own | its own inbox | aborts | aborts |
| never issued: below -1, or not yet returned by any `thread_spawn` | aborts | aborts | aborts |

An abort outside a contained worker ends the program, so "ended" is a
return or a contained abort; the two are not told apart by `qput_to`,
since a sender cannot use the difference, and `thread_wait` tells them
apart for whoever needs to. The abort on a never-issued id is a runtime
diagnostic like `thread_wait`'s (`goose runtime error: qput_to or
thread_watch of a thread id never issued`, and the call's location), and a
contained worker that makes it ends with it. An id cannot be known before
`thread_spawn` returns it, so only a program that computes ids reaches it.

`false` for an ended worker, rather than a silent `true`, keeps one meaning
for the result: the value was not queued. A sender that retries refused
puts must therefore also stop retrying when the receiver is gone. The
receiver's end is permanent, and a `thread_watch` message (§4.6) or a
`thread_wait` tells the sender which it is; in the exchange of §8.2, puts
are never refused while the receiver runs, so a refusal means it ended.
§16 keeps the question.

### 4.4 Limits and backpressure

`qlimit<T>(n)` sets the limit of every queue of `T`: the global queue and
each thread's inbox, each holding at most `n` messages of its own. A
`qput_to` to a full inbox is refused at once, as a `qput` to a full global
queue is, and a full inbox at one worker refuses nothing to another. Lowering
a limit keeps what is queued, as today. One limit per type, not per
destination, is enough for the engine's uses and keeps `qlimit` the one
knob; a program that wants two limits for one payload has two types
(`struct ToJoin { b: Batch }`), as for anything else that has to be told
apart. Messages that events and watches deliver (§4.6, §6) are queued even
into a full inbox, since refusing them would lose them; they count while
they wait, so puts are refused until the inbox is below its limit again.

Nothing blocks. A blocking put would deadlock an exchange as soon as two
workers both wait for room in each other's inbox, each one no longer taking
from its own; with puts that never block and a `select` that waits for
anything, a worker always keeps draining its inbox while it waits. The
sender applies backpressure, in one of two ways:

* **Retry**: a refused put is kept and tried again after the next message
  the sender handles, or after a timed `select`. Simple, and right where
  refusals are rare.
* **Credits**: the receiver gives each sender a window of `k` messages and
  sends a credit back for every `k / 2` it takes, and a sender sends only
  with a credit in hand, waiting for credits in `select` with the rest of
  its inbox. Puts are then never refused, a receiver's inbox holds at most
  `k` messages per sender, and a waiting sender sleeps until exactly the
  moment it may send. This is the exchange's protocol (§8.2), and the usual
  one for streams (HTTP/2's and QUIC's windows, MPI's rendezvous).

### 4.5 Order

Every queue, an inbox or a global queue, is first in, first out, which is
what today's queues are, and what §11.2 is to say in so many words (§14):
if one put returns before another starts, its value is taken first,
whichever threads made them; in particular a thread's puts to one queue
are taken in the order it made them. A message that a thread put before it
sent a second message elsewhere is therefore in its queue by the time the
second can be taken: a "data, then done" protocol works across threads and
queues, which the stop messages of §8.1 rely on.

There is no order across queues. A thread's own inbox for `T` comes before
`T`'s global queue: addressed messages are the more specific ones, and a
worker that has work meant for it does that first (the affinity of §8.1).
Between types, `select`'s rotation decides (§5.3). A protocol that needs an
order between two kinds of message sends them as one type, an enum, or
puts the order in the messages (the exchange's last batch of §8.2 carries
its own end-of-stream mark rather than following it with a message of
another type).

Phase 2 keeps this exactly: one queue's puts are ordered by the tickets
they take (§9.3). Per-sender order alone would have allowed rings per
sender, but would let a message overtake one that was put before it by
another thread; §3.3 shows a shared ticket costs 10 to 35 ns under
contention, which is not worth that.

### 4.6 When a worker ends

A worker ends by returning, or by an abort if it is contained. The runtime
then, in this order:

1. releases its storage, as today;
2. closes its inboxes: later `qput_to`s to it are refused, and the
   messages left in them are discarded, never taken by anyone; closes its
   events, so that later signals return 0 (§6); and cancels the watches it
   made;
3. marks it ended, so that `thread_wait` for it returns;
4. fires the watches on it (below).

So once `thread_wait(w)` has returned, or a watch message on `w` has been
taken: `qput_to(w, v)` is `false`, `w`'s inboxes hold nothing, and every
message `w` put before it ended is in its queue, where it stays until taken,
as today.

A message put to a worker while it is ending may be queued (`true`) and
then discarded unread. This is the rule of every asynchronous queue: a
sender cannot tell a message its receiver read from one it never read,
without an answer from the receiver, and a protocol that needs to know
uses one. Keeping the messages instead would leave them where nobody can
ever take them, since nobody else reads an inbox, and ids are never
reused.

`thread_watch(id, v)` registers a copy of `v`, a flat value, to be put in
the caller's inbox for `v`'s type when worker `id` ends, at step 4 above;
if `id` has already ended, the copy is put at once. A worker may be watched
any number of times, by any threads. Watching main, oneself or a
never-issued id aborts, as `thread_wait` does. The watch message is queued
even into a full inbox; it is dropped if the watcher has ended by then.
Since the message comes after step 3, the watcher's `thread_wait(id)` then
returns at once with the worker's answer, and since every message the
worker put came before its end, a report it sent is already queued.

This is what lets main take reports as they arrive and still learn of an
abort without blocking, which today's run protocol cannot (§2.3, and §8.1
for the code): main waits for the next report or the next end, and is done
once every worker has either reported or aborted, without waiting for any
thread to finish ending.

## 5. `select`

### 5.1 The form

```goose
struct Morsel { table: i32, row_group: i32 }
enum Control { Stop, Cancel }
struct IoDone { worker: i32 }

enum Work { Morsel { m: Morsel }, Control { c: Control }, Io { d: IoDone } }

thread_fn worker(w: i32) {
    loop {
        match select<Work>() {                  // the next Morsel, Control or IoDone
            Morsel m => process(m.m),
            Control c => { break; },
            Io d => reap_reads(),
        }
    }
}
```

* `select<E>() -> E` takes the next message whose type is one of the
  field types of `E`'s variants, and returns it in its variant. It blocks
  until there is one.
* `select<E>(ms) -> E, bool` waits at most `ms` milliseconds, exactly as
  `qget<T>(ms)` does: on a miss it gives `E`'s zero value (variant 0 with a
  zeroed payload, as a missed `qpoll` gives for an enum) and `false`, and
  `ms` of zero or less does not wait, so `select<E>(0)` polls several types
  at once.
* `E` is an enum. Each variant has exactly one field, whose type is the
  type that variant receives; the field's name is free. A variant receives
  from the caller's inbox for its field's type and from that type's global
  queue, inbox first, as `qget` does. The field types are distinct (two
  variants receiving one type would leave the choice between them
  undefined), and each is a type `qget<T>` accepts: flat, holding no index
  types (§3.11). A zero-size type cannot be a field (§3.4), so a message
  carries at least a byte (`enum Control { Stop, Cancel }` is one).
* `E` may be generic (`enum LoopMsg<M> { App { m: M }, Io { d: IoDone } }`),
  and may be named in either mode: `select<E>()` for a fixed-mode `E`,
  `select<E..>()` when a field's type is variable-size (a string), as for
  any enum value (§3.5). A resizable field type (`u8[>..]`) is refused in
  this version ("select cannot receive a resizable value yet; take it with
  qget"); §16.

The field-per-variant form keeps senders free of the receiver's enum: a
sender puts a `Morsel` or an `IoDone`, and each receiver wraps what it
receives in an enum of its own, so one type can be received by several
`select`s, and a library's loop can receive the program's types beside its
own (§7). A form in which each variant type were itself the message
(`qput_to(w, Work.Stop {})`) would tie every sender to one receiver's enum,
and a library could not add its types to a program's.

### 5.2 What it waits on, and what it returns

A `select` waits on the caller's inbox and the global queue of each field
type, and on its deadline. Timeouts are the deadline. External events and
the ends of watched workers are messages (§6, §4.6), so nothing else is a
source, and a thread is woken by nothing but a message or its deadline.

It takes exactly one message, the one it returns. The others stay queued:
a `select` is a take, not a peek, so there is no window in which a message
is reported ready and then taken by another thread, and no "ready" result
the program must recheck.

### 5.3 Fairness and starvation

A `select` checks its sources in a rotation that each call site keeps for
each thread: it starts at the variant after the one that site returned
last, and takes the first message it finds. A type that has a message is
therefore taken within as many calls of that site as `E` has variants,
however much the other types receive: no type starves another. The
rotation is deterministic, so a program that sees the same messages in the
same order selects them in the same order, which a random choice (Go's,
tokio's by default) would not give.

Within one type, the inbox comes before the global queue (§4.5). A thread
whose inbox for `T` never empties never takes `T` from the global queue:
that is the point of addressing. Go's scheduler takes from its global run
queue every 61st time to avoid exactly this, which trades the starvation
for a rule a program cannot see; here the rule is the one the program
wrote. §16 keeps the question.

A program that wants priority asks for it: it `qpoll`s the urgent type
first and then `select`s, or puts the urgent kind and the rest in separate
`select`s. A `biased` form that checks variants in declaration order is
deferred until a program needs it (§16).

When a `select` has to wait, it takes the message that woke it first, so a
put that wakes one sleeping thread is taken by that thread unless a thread
that was awake takes it first; then the rotation continues after that
variant.

### 5.4 Spurious wake-ups

`select` and `qget` never return spuriously: a return is a message or, for
the timed forms, the deadline, measured on the monotonic clock. The
runtime absorbs every spurious wake-up of the operating system's primitive
(a condition variable's, a futex's) by checking its sources again, and a
thread that was woken for a message another thread took first goes back to
waiting with the time it has left. An event's message (§6) is a message
like any other, so a signal never wakes a `select` that then has nothing
to return.

### 5.5 What waiting costs

When nothing is ready, a `select` costs a check of its sources and then a
sleep that uses no CPU. In phase 1, a check is a lock and an unlock per
queue, two queues per variant, about the 13 ns of today's empty `qpoll`
each, and the sleep registers the thread with each queue and waits on its
own condition variable. In phase 2 a check is two loads per variant from
cache lines that stay in the caller's cache while nobody writes them, a
few nanoseconds; then the thread spins, rechecking, for about the time a
wake-up costs (§9.5), and only then parks. A sleeping thread is woken by
one system call from the thread whose put it is waiting for; a put to a
queue nobody is parked on makes no system call at all. The deadline is the
wait's timeout, so a timed `select` needs no timer thread.

### 5.6 When one queue is enough

`select` is for sources that cannot share a type. Messages that one set of
senders sends to one receiver can share an enum type and one queue, which
`qget` takes in the order they were sent (`enum ToWorker { Morsel { … },
Stop }`, put as `ToWorker` values). `select` is needed when the types come
from different places: the program's messages beside a library's, the
global queue's work beside a thread's control messages, events and watches
beside replies; when kinds must not wait behind each other in one FIFO; and
when a small message must not occupy a fixed-mode enum's room for a 32 KB
one.

## 6. Events from C

### 6.1 Events

```goose
struct IoDone { worker: i32 }

let done = event(IoDone { worker: 3 });   // an i64, for C
shim_read_async(fd, offset, length, tag, done);
// ... and when C has signalled it, IoDone { worker: 3 } is in the inbox:
match select<Work>() {
    Io d => reap_reads(),
    _ => {},
}
event_close(done);
```

* `event(v) -> i64` makes an event belonging to the calling thread and
  holding a copy of `v`, a flat value. The id is positive and never
  reused; it is the program's to hand to C.
* Signalling `e` while it is open puts a copy of `v` in its owner's inbox
  for `v`'s type, unless a copy from `e` is already waiting there. While
  one waits, further signals merge into it; once the owner has taken it,
  the next signal puts a new copy. A signal therefore wakes the owner at
  least once after it was made, and a burst of signals wakes it once.
* The copy is queued even into a full inbox (§4.4).
* `event_close(e)` closes an event of the calling thread: later signals
  are ignored, and a copy already in the inbox stays there to be taken.
  Closing an event of another thread, a closed one, or a number that is no
  event aborts. A thread's events close when it ends (§4.6).

An event carries no data beyond `v`, which is fixed when it is made: what
happened is the C library's to say when the thread asks it (`reap_reads`
calls an `extern fn` that hands back the completed reads), and a thread
that wants to tell sources apart makes an event for each, with a `v` of
its own. This is the shape of an eventfd, of libuv's `uv_async_t` and of
an io_uring completion queue: the signal says "look", and is merged while
nobody has looked; the data waits where the library keeps it.

### 6.2 The C side

```c
#include "goose.h"

/* Signals the event `e`: a copy of its message goes to its thread's
   inbox, unless one is already waiting there. Returns 1 if `e` is open,
   0 if it was closed, its thread has ended, or it is not an event. */
int gs_event_signal(int64_t e);
```

* **Any thread, any time.** A Goose thread or one the C library started,
  before the owner first waits, while it waits or while it runs, and after
  it has ended or closed the event (which returns 0, so a C library that
  outlives its user's interest needs no handshake to stop).
* **Thread-safe by construction.** An event is a record in a table that
  the runtime never shrinks or frees while the program runs, found from the
  id's low bits; the rest of the id is a generation that the record's state
  word holds beside the state. The call changes that word with one atomic
  compare-exchange, which checks in the same step that the record is still
  the event `e` names and that its copy is not already queued; then it
  queues the copy and wakes the owner if the owner is parked. It shares no
  state with Goose code beyond that word, and runs no Goose code. In phase
  1 the queueing takes the inbox's mutex for a few tens of nanoseconds and
  allocates nothing, since the queued copy is the event's own node; in
  phase 2 it is a put like any other (§9.3, §9.4).
* **Not from a signal handler**, since a put may take a lock (§16).
* **Linkable from a package's C.** `gs_event_signal` has external linkage
  in every build of the runtime, the runtime object and the standalone
  unit alike, so that a native part compiled on its own
  (`docs/packages.md`) links to it, and `goose.h` declares it beside
  `gs_bld_append`.

Goose code has no `event_signal`: one Goose thread wakes another with
`qput_to`. Nor does C get a general `qput_to`: C would have to build a Goose
value's bytes, valid at its type, and name a queue, where an event lets
Goose build the value and C only say when.

### 6.3 A completion shim

The engine's reads are synchronous today (`pread` in the worker). A shim
that prefetches the next morsel's columns while the worker computes on the
current one runs the reads on a thread of its own, into memory of its own,
since C may not keep a borrowed Goose buffer past the call that lent it
(§7.10); the worker copies a completed read into its buffer during a later
call:

```c
/* src/c/shim.c (sketch): the shim's I/O thread. Jobs and completions are
   the shim's own, under its own lock. */
static void *io_thread(void *arg) {
    for (;;) {
        struct job *j = next_job();              /* blocks on the shim's own condition variable */
        j->result = pread(j->fd, j->buf, (size_t)j->length, (off_t)j->offset);
        finish(j);                               /* onto the completed list */
        gs_event_signal(j->done);                /* wake the worker that asked, once */
    }
    return NULL;
}
```

```goose
// src/c/shim.goose (sketch)
extern fn shim_read_async(fd: i64, offset: i64, length: i64, tag: i64, done: i64) -> bool;
extern fn shim_completed(tags: i64[>..]&);                 // the tags finished since the last call
extern fn shim_take(tag: i64, out: u8[:]) -> i64;          // copies a finished read: its bytes, or -errno
```

§8.3 shows the worker's side. A zero-copy version is the business of the
mapped files of the shared-memory track, not of this note: an event says
when, not where.

### 6.4 File descriptors

The issue names a file-descriptor source as the other form an external
event could take: `select` waiting until an `fd` is readable, so that a
thread can sleep on an eventfd, a socket or an io_uring ring and on its
messages together. It is not in phase 1:

* It is platform-specific (an `fd` on POSIX, a `HANDLE` or a `SOCKET` on
  Windows), where `gs_event_signal` is the same everywhere.
* It changes how a thread sleeps: on `poll` with its own eventfd beside
  the user's descriptor, instead of on a futex, and puts would have to wake
  either kind.
* Every library with a descriptor can bridge to `gs_event_signal` with a
  thread of its own, at the cost of one hop per batch of completions.

It fits the design without changing `select`: an `event_fd(fd, v)` would
be an event that the runtime signals itself while `fd` is readable, and
a thread that holds one sleeps on `poll` instead of its futex. §16 records
when to add it.

## 7. Coroutines

coroutines.md proposes stackless coroutines whose frames are ordinary
fixed-size values, driven by one builtin, `resume`, and scheduled by
libraries: event loops, timers, channels, cancellation and `select` are
library code (its §4.13), and a coroutine tells its loop what it waits for
with a typed `yield` rather than by registering a callback (§2.7). Its
server runs one loop per worker, thread-per-core, with the loop's pools as
the worker's globals (§2.5, §5). This note supplies what such a loop needs
from the runtime, and nothing that would conflict with it.

### 7.1 The one blocking call

Inside one thread, nothing needs the runtime: which coroutine waits for
what, timers kept as a heap of deadlines, a coroutine-level `select` that
waits for whichever of two waits completes first, and channels between
coroutines on one thread (an array and a `Wait` variant, coroutines.md
§4.13) are the library's data. What the library cannot write is the wait
of the thread itself, when no coroutine can run: sleep until a message
arrives from another thread or from C, or until the next timer, and then
say which came. That is `select<E>(ms)`, with `E` listing the types the
loop's coroutines wait for, `ms` the time to the next timer, and events
(§6) turning a C reactor's completions into messages. It is the only
runtime primitive a coroutine library needs, and it keeps coroutines.md's
properties:

* **No callbacks.** C signals an event by its id, and the runtime gives
  the loop a message; nothing calls into Goose code, and the loop decides
  what to resume, as coroutines.md §2.7 wants.
* **Zero cost otherwise.** A program without `qput_to`, `select`, events
  or watches runs its queues as it does today; the inbox checks in `qget`
  cost a load that finds them empty (§9.3).
* **Thread-per-core.** Each loop is a thread with its own inbox, so
  addressing a loop is addressing its thread, and a request and its reply
  find their way without a shared queue.

### 7.2 A loop

A sketch in coroutines.md's placeholder syntax (`coro fn`, `yield`,
`resume`), with a library-defined protocol between tasks and the loop:

```goose
// What a task waits for (yield), and what the loop resumes it with.
enum Wait { Reply { tag: i64 }, Timer { at_ns: i64 }, Read { tag: i64 } }
enum Woke { Value { v: i64 }, Timeout, Done { bytes: i64 } }

// What other threads and C send to this loop's thread.
struct Rpc { tag: i64, v: i64 }                 // an answer, sent with qput_to(req.from, ...)
struct IoDone { ring: i64 }                     // the reactor's event
enum LoopMsg { Reply { r: Rpc }, Io { d: IoDone } }

struct Req { from: i64, tag: i64, key: i64 }   // a request; the server answers to `from`

coro fn fetch(server: i64, key: i64) -> i64 resume Woke {
    let tag = next_tag();
    qput_to(server, Req { from: thread_id(), tag: tag, key: key });
    let woke = yield Wait.Reply { tag: tag };
    match woke { Value r => r.v, _ => -1 }
}

fn run_loop() {
    loop {
        run_ready_tasks();                       // resume(...) each runnable frame to its next yield
        let m, got = select<LoopMsg>(ms_until_next_timer());
        guard got else {
            fire_timers();
            continue;
        }
        match m {
            Reply r => wake(r.r.tag, Woke.Value { v: r.r.v }),
            Io d => {
                for c in reactor_completions(d.d.ring) { wake(c.tag, Woke.Done { bytes: c.bytes }); }
            },
        }
    }
}
```

The loop keeps its waiting tasks in a pool, indexed by tag, as the server
of coroutines.md §5 keeps them by descriptor. A thread blocked in this
`select` uses no CPU; a reply or a completion wakes it with one system call
at most, and a reply that arrives while it is still running costs nothing
beyond the put (§9.5).

### 7.3 Frames and replies across threads

A flat frame is a flat value (coroutines.md §4.9), so `qput_to(w, frame)`
hands a suspended task to worker `w`, whose loop receives it as a variant
of its `select` (`Task { t: serve }`) and adds it to its pool: the explicit
work distribution coroutines.md §2.5 describes, now addressed to the
worker that owns the task's data rather than to whichever worker takes the
global queue's next message. A request carries `thread_id()` as its reply
address, so replies reach the loop that asked, which a global reply queue
cannot promise once two loops send requests.

### 7.4 What stays a library

Timers, cancellation (a resume value), structured concurrency, the
coroutine-level `select`, channels within a thread, the reactor and its
kernel interface: all of coroutines.md §4.13 stays out of the language.
What this note adds is the thread-level wait, addressing, and the bridge
from C, which are about threads, not coroutines, and are useful without
them: §8's engine has no coroutines.

## 8. The engine's three uses

The engine's types, from its `src/runtime.goose`, with the additions this
design makes possible. The code is a sketch of what the engine would write;
the scheduling and error handling of `sched.goose` are left out, and the
functions it does not define (`process`, `partial`, `combine`, `consume`,
`partition_of`, `my_rows`, `prefetch`, `land`) stand for the engine's own.
Each block was checked by `goose check` against stubs for those and for
the proposed builtins.

### 8.1 Morsel dispatch

Morsels stay on the global queue, so an idle worker takes the next one and
load balancing stays dynamic, as DuckDB's is. Control goes to one worker,
reports go to main's inbox, and main learns of every worker's end by a
watch:

```goose
struct Morsel { table: i32, row_group: i32 }
enum Control { Stop, Cancel }                    // to one worker
struct Ended { worker: i32, id: i64 }            // a watch's message
struct Args { main: i64, worker: i32 }           // where the report goes, and who this is

enum Work { Morsel { m: Morsel }, Control { c: Control } }

thread_fn worker(args: Args) {
    var state = State { .. };
    var report = WorkerReport<Partial> { worker: args.worker, .. };
    var running = true;
    while running {
        match select<Work>() {
            Morsel w => process(state, w.m, report),
            Control c => {
                match c.c {
                    // Every morsel was queued before main sent the stops (4.5):
                    // what is left is in the queue, and a miss means the end.
                    Stop => loop {
                        let m, more = qpoll<Morsel>();
                        guard more else { break; }
                        process(state, m, report);
                    },
                    Cancel => {},
                }
                running = false;
            },
        }
    }
    report.partial = partial(state);
    qput_to(args.main, report);
}

enum Collect { Report { r: WorkerReport<Partial> }, Ended { e: Ended } }

// Returns how many workers aborted, and how many ends are still to come.
fn run(morsels: const Morsel[:], workers: i64, total: Partial&) -> i64, i64 {
    for m in morsels { qput(m); }
    var ids: i64[>..] = [];
    for w in workers {
        let id = thread_spawn_contained(worker, Args { main: thread_id(), worker: w as i32 });
        thread_watch(id, Ended { worker: w as i32, id: id });
        ids.push(id);
    }
    for id in ids { qput_to(id, Control.Stop); }
    var reported = 0;
    var aborted = 0;
    var ended = 0;
    while reported + aborted < workers {
        match select<Collect>() {
            Report r => {
                combine(total, r.r.partial);
                reported++;
            },
            Ended e => {
                ended++;
                var why: u8[>..] = [];
                if !thread_wait(e.e.id, why) { aborted++; }   // at once: it has ended
            },
        }
    }
    return aborted, workers - ended;
}

// The ends still to come, taken once the result is out.
fn settle(pending: i64) {
    for i in pending { qget<Ended>(); }
}
```

* A worker that aborts sends no report, and its watch counts it; a worker
  that returns has its report queued before its watch fires (§4.6). So
  main has the result with the last report, without waiting for 16 threads
  to finish releasing their memory: the 40 ms that `docs/pipeline.md` found
  between the last report and the end of a run at SF10 come after the
  result instead of before it. Main writes the result and then `settle`s,
  so that no `Ended` is left for the next run's `select`; a later version
  can let the next run start while they end.
* `qput_to(ids[w], m)` before the stops gives worker `w` morsels of its own,
  which it takes before the global queue's (§4.5): affinity, for a morsel
  whose data a worker has cached, with stealing from the global queue for
  the rest.
* The old protocol, stops on the global queue behind the morsels, keeps
  working unchanged; `Control` adds a cancel that reaches one worker
  without waiting behind the morsels.
* Cost. Taking a morsel costs a worker about 4.8 µs today when 16 take at
  once (§3.4), and 1.5 µs in a Q1 run. In phase 2 a take is a ticket and a
  copy from a slot: about 100 ns when takes do not collide, and at most
  1.6 µs when 16 workers do nothing but take (§9.8's 10 M/s). Morsels are
  milliseconds of work, so this matters for smaller morsels and for many
  short queries rather than for Q1.

### 8.2 A partitioned exchange

Every worker scans its morsels and sends each row to the worker that owns
its key's partition, in batches of 2048 rows; every worker is also the
receiver of its own partitions. Credits bound what each receiver holds and
let a sender that has no credit sleep until it gets one, while it goes on
receiving:

```goose
let ROWS = 2048;
let WINDOW = 8;                                  // batches in flight from one sender to one receiver
let MAX_WORKERS = 64;

// 2048 rows of two columns: 32 KB. `last` ends its sender's stream.
struct Batch { from: i32, rows: i32, last: bool, keys: i64[ROWS], values: i64[ROWS] }
struct Credit { from: i32, n: i32 }              // receiver `from` lets its sender send n more
struct Peers { count: i32, ids: i64[MAX_WORKERS] }   // every worker's id, from main

enum Exchange { Batch { b: Batch }, Credit { c: Credit } }

root struct Outbox {
    staged: Batch[>..] = [],                     // per receiver, the batch being filled
    credits: i64[>..] = [],                      // per receiver, batches it may still be sent
    taken: i64[>..] = [],                        // per sender, batches taken since its last credit
    finished: i64 = 0,                           // senders whose last batch has come
}

// Takes one message: a batch to join or aggregate, or a credit.
fn receive(me: i32, peers: const Peers&, out: Outbox&, state: Joiner&) {
    match select<Exchange>() {
        Batch b => {
            consume(state, b.b);
            let s = b.b.from;
            out.taken[s]++;
            if out.taken[s] == WINDOW / 2 {
                qput_to(peers.ids[s], Credit { from: me, n: WINDOW / 2 });
                out.taken[s] = 0;
            }
            if b.b.last { out.finished++; }
        },
        Credit c => { out.credits[c.c.from] += c.c.n; },
    }
}

// Sends the batch staged for receiver d, after waiting for a credit if it has none.
fn send(me: i32, d: i64, peers: const Peers&, out: Outbox&, state: Joiner&) {
    while out.credits[d] == 0 { receive(me, peers, out, state); }
    let ok = qput_to(peers.ids[d], out.staged[d]);
    assert(ok);                                  // with a credit in hand, only an ended receiver refuses
    out.credits[d]--;
    out.staged[d].rows = 0;
}

thread_fn exchange_worker(me: i32) {
    let peers = qget<Peers>();                   // from main, in this worker's inbox
    let w = peers.count as i64;
    var out = Outbox { .. };
    var state = Joiner { .. };
    for d in w {
        out.staged.push(Batch { from: me, rows: 0, last: false, .. });
        out.credits.push(WINDOW);
        out.taken.push(0);
    }
    for row in my_rows() {                       // the worker's morsels, row by row
        let d = partition_of(row.key, w);
        let s .= out.staged[d];
        s.keys[s.rows] = row.key;
        s.values[s.rows] = row.value;
        s.rows++;
        if s.rows == ROWS { send(me, d, peers, out, state); }
    }
    for d in w {
        out.staged[d].last = true;               // a last batch to every receiver, rows or not
        send(me, d, peers, out, state);
    }
    while out.finished < w { receive(me, peers, out, state); }
    finish(state);
}
```

* **No deadlock.** No thread blocks on a put, and a worker waiting for a
  credit keeps taking its own batches, so every worker drains its inbox,
  and every credit it owes is sent.
* **Bounded memory.** A receiver's inbox holds at most `WINDOW` batches per
  sender: 16 × 8 × 32 KB = 4 MB per worker at 16 workers. `qlimit<Batch>`
  can stay unset; with credits, a refusal can only mean the receiver ended.
* **Order.** A sender's batches reach a receiver in the order sent (§4.5),
  so its `last` batch is its last, whatever credits are doing meanwhile.
* **Cost.** Each batch is copied once into the queue and once out of it in
  phase 2 (§9.6), 1.7 to 3.7 µs per batch on one pair of cores (§3.3):
  about 10 to 20 GB/s per receiver, against the hundreds of MB/s to GB/s
  the engine needs. A copy-free exchange would need the frozen regions of
  the shared-memory track; the queue's part is to add nothing to the two
  copies.

### 8.3 Control messages and I/O completions

A worker that prefetches the next morsel's columns with the shim of §6.3
waits for morsels, control and its reads together:

```goose
struct IoDone { worker: i32 }
enum Work { Morsel { m: Morsel }, Control { c: Control }, Io { d: IoDone } }

thread_fn worker(args: Args) {
    let done = event(IoDone { worker: args.worker });
    var reads = Reads { .. };                    // the reads in flight, by tag
    var running = true;
    while running {
        match select<Work>() {
            Morsel w => {
                prefetch(reads, w.m, done);      // shim_read_async(..., done) per column
                process(w.m);
            },
            Control c => { running = false; },
            Io d => {
                var tags: i64[>..] = [];
                shim_completed(tags);            // every read finished since the last look
                for t in tags { land(reads, t); }   // shim_take(t, buffer) into the morsel's buffers
            },
        }
    }
    event_close(done);
}
```

The worker sleeps only when it has no morsel to process and no read has
completed; a read that completes while it computes costs it nothing until
it next selects, and many that complete together wake it once. Main stops
or cancels one worker with `qput_to(id, Control.Cancel)`.

## 9. Faster queues

### 9.1 Where the time goes today

From §3.4: a contended `pthread_mutex` that puts takers to sleep; a
`pthread_cond_signal` system call on every put to a queue whose takers
sleep, and wake-ups of about 6 µs each; `malloc` of fresh pages for a
growing queue and `free` on another thread (0.95 µs for 32 KB); and four
copies of a fixed-size message where two are needed. Phase 2 removes each, without
changing anything a program can observe: each queue first in, first out
(§4.5), exact limits, `qput` never blocking, inbox before global, the zero
values of misses, and the deadlines of `qget(ms)` and `select(ms)`.

### 9.2 Options

| option | no `malloc` per message | no lock for all | keeps §4.5's order | verdict |
|---|---|---|---|---|
| node pool behind today's lock | yes | no | yes | half the problem; the lock is §3's biggest cost |
| two locks, one for putters, one for takers (Michael and Scott) | with a pool | takers still share one | yes | 16 takers still collide (`drain`) |
| rings per sender (SPSC), takers scan them | yes | yes | per sender only | fastest for an exchange, but gives up §4.5, and a global queue has many takers per ring |
| sharded queues, a sender's shard by its id | with a pool | mostly | per sender only | the same loss, and takers scan shards |
| one ticket ring per queue, `fetch_add` (or a compare-exchange) to put, a compare-exchange to take, slots in recycled segments | yes | yes | yes | **chosen** |
| batched `qput_n`/`qget_n` | no | no | yes | saves what §3.3 shows costs least; a later addition if measured (§16) |

The chosen queue is in the family of Vyukov's bounded MPMC queue (a slot
per ticket, with a sequence number saying whose turn it is) and of
crossbeam's `SegQueue` (unbounded, slots in linked blocks), with four
changes: segments are recycled, never freed, so a reader holding a stale
pointer reads valid memory; limits are exact; an inbox's tickets carry its
owner's generation; and payloads larger than a slot live in the sender's
chunks.

### 9.3 The queue: tickets, segments, slots

A queue (a type's global queue, or one thread's inbox for a type) holds
two 64-bit counters that never wrap, `tail` (the next ticket to put) and
`head` (the next to take), on cache lines of their own, and a chain of
segments of 64 slots. A slot is 64 bytes, one cache line: a sequence word,
the message's size and kind, and 48 bytes that hold the message itself or
point to it.

* **Put.** An unlimited global queue takes a ticket with `fetch_add(tail,
  1)`. A limited queue, and every inbox, takes it with a compare-exchange
  that first checks `tail - head < limit`, which keeps the limit exact: a
  refusal is the moment the queue held its limit, and a success the moment
  it held less. For an inbox the same compare-exchange checks its owner
  (below). Ticket `t`
  is slot `t % 64` of the segment for `t / 64`. The putter that first needs
  a segment past the last links one with a compare-exchange on the last
  one's `next`; a putter that loses the race gives its segment back.
  Segments come from a free list: a few cached per thread, in front of a
  global list under a mutex, so a put takes a lock at most once in 64
  messages, and usually never. It writes the message (§9.4), stores `seq =
  t + 1` with release order, and then, after a full fence, reads the
  queue's count of parked threads; if it is zero, which is the common case,
  the put is done (§9.5).
* **Take.** A taker reads `head`, `h`, and the sequence of slot `h`. If the
  slot is published (`seq == h + 1`), a compare-exchange of `head` from
  `h` to `h + 1` makes the message its own. If it is not, and `h ==
  tail`, the queue is empty. If `h < tail`, a put holds ticket `h` and is
  writing; the taker waits for it, which takes nanoseconds, since a large
  message was copied before its ticket was taken (§9.4). So a take never
  misses a message whose put returned, and order is ticket order.
* **Done.** After the generated code has copied the message out, the slot
  is released: its segment counts it, and a segment whose 64 slots are all
  taken goes back to the free list once `head` has passed it. Segments are
  never returned to the system while the program runs, and each records
  its first ticket, which a reader checks.
* **Close and reuse.** An inbox's `tail` carries, in its top 16 bits, the
  generation of the thread record that owns it, which the sender read
  with the record's id; its compare-exchange fails if the generation has
  changed. A thread's end (§4.6) sets the generation to "closed": later
  puts are refused, and the closing thread discards exactly the tickets
  below the value it replaced, waiting for any still being written. When
  the record is reused for a later thread it gets a new generation, so a
  put meant for a thread that ended can never land in the inbox of the
  thread that reuses its record, and no put can slip in after the close
  and be left behind. Global queues never close and take no generation.
* **Inbox first.** A take of `T` looks at the caller's inbox for `T` (one
  load of `head` and one of `tail`, which stay in its cache while nobody
  addresses it) and then the global queue.

The contended operations are one `fetch_add` per put to an unlimited
global queue (a compare-exchange for an inbox or a limited queue), and per
take one compare-exchange and the segment's count: 10, about 35 and 10 ns
on this machine with 16 threads at them (§3.3), against the microseconds
a contended lock costs.

### 9.4 Payloads: in the slot, or in the sender's chunks

* A message of up to 48 bytes is written into its slot: a morsel, a
  control message, a credit, a 16-byte test message.
* A larger one is copied, before the ticket is taken, into the sending
  thread's current **chunk**, 256 KB taken by bumping an offset, and the
  slot holds its address and its chunk. A chunk counts the messages in it
  that have not been taken, plus one while it is a thread's current chunk;
  the taker's done decrements it, and whoever brings it to zero puts the
  chunk on the free list. A message larger than 64 KB gets a chunk of its
  own, rounded up to a multiple of 64 KB and kept on a free list by size.
* An event's or a watch's message (§4.6, §6) stays in the event's or the
  watch's record, and its slot points there; taking it clears the event's
  "waiting" state, which is how signals merge.

No message `malloc`s: chunks and segments come from free lists, and from
the system only when a free list is empty. Memory a queue grows into for
the first time still costs the system's page faults (§3.4's 14.7 µs
`burst` put is mostly those), but only the first time: a queue in steady
state reuses warm chunks, and a block taken on another thread costs a
decrement rather than a remote `free`. Chunks belong to the runtime, not
to the thread, so a message outlives its sender (§11.2), and a chunk
stays allocated while any message in it is queued, which the queues'
limits bound. Memory taken once is kept until `trim_memory()` (§16).

### 9.5 Waiting: a parker per thread

Every thread has a **parker**: a 32-bit state, `RUNNING`, `WAITING` or
`CLAIMED` by a queue, on which it sleeps. Linux sleeps on it with `futex`,
Windows 8 and later with `WaitOnAddress`, macOS 14.4 and later with
`os_sync_wait_on_address`; elsewhere it is phase 1's mutex and condition
variable. Every queue counts the threads parked on it and lists them under
a spinlock that only waiting and waking take.

* **Spin, then park.** A take or `select` that finds nothing checks again,
  pausing between checks, for about the time a wake-up costs (6 µs here;
  measured per platform and kept as `GS_QSPIN_NS`), unless its deadline is
  sooner. An answer that comes back inside that, as in a ping-pong or a
  pipeline, then costs about the 0.24 µs of a spinning round trip instead
  of the 11.8 µs of a sleeping one (§3.3). Only then does the waiter
  register with each of its queues, check them once more, and park.
  Spinning is bounded by what a wake-up costs, so a wait that ends up
  parking spends at most that much more CPU than it does today, and a
  thread that waits long sleeps as it does today.
* **A put wakes only the parked.** The fence after publishing and the
  waiter's fence after registering order the two, so either the put sees
  the waiter or the waiter sees the message; when no thread is parked, the
  put costs a load and makes no system call.
* **One message, one thread.** A put that finds parked threads claims one
  (a compare-exchange of its state from `WAITING` to `CLAIMED` by this
  queue) and wakes it; a thread already claimed by another queue is passed
  over. A claimed thread takes from the queue that claimed it first (§5.3),
  so the message that woke it is not left to a thread that sleeps on; and
  if a claimed thread finds the queue empty, the message was taken by a
  thread that was awake, which is just as good. There is no thundering
  herd, and no message left behind with its takers asleep.

Phase 1 implements the same protocol with each queue's mutex in place of
the fences and the per-thread mutex and condition variable as the parker.

### 9.6 Copies

The semantics copy a value in and out (§11.2): two copies. Phase 2 makes
the generated code do exactly two:

* `qput(m)` and `qput_to(id, m)` pass the address of `m` when it is an
  lvalue, rather than copying it into a temporary first; the runtime copies
  it once, into a slot or a chunk.
* A take copies straight into its destination: the variable that receives
  it, the payload of `select`'s result, or the data stack's top for a
  variable-size or resizable message, which the code already does for those
  (§10).

For 32 KB this halves the copying of both sides, from four copies per
message to the two, 1.7 to 3.7 µs, that §3.3 measures for one copy in and
one out.

### 9.7 Finding an inbox

`qput_to(id, …)` finds thread `id`'s record. Thread records become
type-stable in phase 1: a record is recycled for a later thread instead of
freed, with its id changed, so a pointer to one is always safe to read and
a reader checks the id it finds. The id-to-record map is written under
`gs_threads_mutex` when a thread starts or ends. Phase 1 reads it under
that mutex; phase 2 gives each thread a small cache of the records it
addressed last, checked against the id on every use, so an exchange's puts
to the same 16 workers never take the mutex. The recycled records keep
§11.2's promise that nothing is retained per completed worker (beyond a
contained abort's bit): they are a pool as large as the most threads that
were ever live at once, and an ended worker's inboxes, events and watches
are emptied before its record goes back to it.

### 9.8 What it should cost

`bench/queues.py` on this workspace decides. #6 is done when no cell of
§3.2 is more than 10% slower than the baseline, and these targets, set
from the floors of §3.3, hold:

| figure | today (§3.2) | target | from |
|---|---:|---:|---|
| `rt1`, 32 KB | 4.1 µs | at most 2 µs | two copies in cache, not four |
| `empty`, a poll that finds nothing | 13 ns | at most 10 ns | four loads from lines nobody writes |
| `rt2`, 16 B, median | 13.6 µs | at most 2 µs | the answer arrives while the waiter spins (0.24 µs) |
| `drain`, 16 B, 1 consumer | 22.9 M/s | at least 20 M/s | no worse alone |
| `drain`, 16 B, 2 to 16 consumers | 3.4 to 4.4 M/s | at least 10 M/s each | a compare-exchange and a count per take, 45 ns |
| `tput`, 16 B, every pair of counts | 0.20 to 3.56 M/s | at least 5 M/s each | no wake-up while takers are awake |
| `tput`, 32 KB, 1 × 1 | 9.8 GB/s | at least 12 GB/s | one copy out from another core, 1.85 µs |
| `tput`, 32 KB, every pair of counts | 3.9 to 38.6 GB/s | at least 10 GB/s each | no allocator in the path |

Phase 1 changes no queue's speed by design; it must stay within 10% of
the baseline, with `select`, inboxes and events added.

## 10. The generated C

The compiler keeps one `gs_queue` global per type. Phase 1 changes the
interface between generated code and runtime once, so that phase 2 changes
only the runtime: a take hands back a view of the message and a token,
which the code copies from and then gives back.

```c
typedef struct gs_qmsg { const uint8_t *data; int64_t size; void *hold; } gs_qmsg;

GS_API void gs_qinit(gs_queue *q);                     /* gives the type its index too */
GS_API uint8_t gs_qput(gs_queue *q, const void *data, int64_t size);
GS_API uint8_t gs_qput_to(gs_queue *q, int64_t id, const void *data, int64_t size,
                          const char *file, int line);
GS_API void gs_qget(gs_queue *q, gs_qmsg *m);           /* blocks */
GS_API uint8_t gs_qwait(gs_queue *q, int64_t ms, gs_qmsg *m);   /* qget(ms); qpoll is ms 0 */
GS_API int64_t gs_qselect(gs_queue *const *qs, int64_t n, int64_t ms, uint32_t *at, gs_qmsg *m);
GS_API void gs_qdone(gs_qmsg *m);                      /* after the copy */
GS_API int64_t gs_thread_self(void);                   /* thread_id() */
GS_API int64_t gs_event_new(gs_queue *q, const void *data, int64_t size);
GS_API void gs_event_close(int64_t e, const char *file, int line);
GS_API void gs_thread_watch(int64_t id, gs_queue *q, const void *data, int64_t size,
                            const char *file, int line);
int gs_event_signal(int64_t e);                         /* external linkage, also in goose.h */
```

`gs_qselect` returns the index of the queue it took from, or -1 at its
deadline; `ms` below zero blocks, and the code passes `select<E>(ms)`'s
`ms` clamped to at least zero, as `qget(ms)` does. `at` is the call site's
rotation. For

```goose
qput_to(id, Job { n: 1 });
let j = qget<Job>();
let w = select<Work>();
```

the C is, with `Work` the enum of §5.1:

```c
static gs_queue gs_q_Job_g = GS_QUEUE_INIT;
static GS_TLS uint32_t gs_sel0;                        /* the select site's rotation, per thread */

    Job_g t1 = { 1 };
    uint8_t t2 = gs_qput_to(&gs_q_Job_g, id_g, &t1, 8, gs_file0, 3);

    gs_qmsg t3;
    gs_qget(&gs_q_Job_g, &t3);
    GS_MEMCPY(&j_g, t3.data, sizeof(j_g));             /* straight into j (phase 2) */
    gs_qdone(&t3);

    static gs_queue *const t4[3] = { &gs_q_Morsel_g, &gs_q_Control_g, &gs_q_IoDone_g };
    gs_qmsg t5;
    int64_t t6 = gs_qselect(t4, 3, -1, &gs_sel0, &t5);
    w_g.tag = (uint8_t)t6;                             /* variant i receives queue i */
    GS_MEMCPY(&w_g.u, t5.data, (size_t)t5.size);       /* the one field is the payload */
    gs_qdone(&t5);
```

A variant's payload struct has one field, so the message's image is the
payload's, and one copy into the union builds the variant; for a
variable-mode `E..` the destination is the data stack's top, with the tag
first, as for any variable-size value. A missed timed `select` zeroes the
destination, as a missed `qpoll` does. `event(v)` and `thread_watch(id,
v)` pack `v` as `qput` does and pass it with its queue; the runtime keeps
the copy. `thread_id()` is `gs_thread_self()`. The queues' `gs_qinit`
calls in `gs_program_init` also number the queue types, in the sorted order
the compiler already emits them, which is how a thread record finds its
inbox for a type.

## 11. The compiler's pieces

* **Builtins** (`builtins.h`): `B_THREAD_ID` (`thread_id`, 0 arguments,
  returns `i`), `B_QPUT_TO` (`qput_to`, 2), `B_SELECT` (`select`, 0 to 1,
  `BF_TYARGS`), `B_EVENT` (`event`, 1), `B_EVENT_CLOSE` (`event_close`, 1),
  `B_THREAD_WATCH` (`thread_watch`, 2). User functions of these names keep
  their calls, as for every builtin (`CheckNamedCall`): the one user
  `select` in the tests, `root_owner_choices.goose`'s, still resolves.
* **Checker** (`typecheck_builtins.h`, `CheckBuiltin`). `qput_to`: the id
  is an `i64`, the value is checked as `qput`'s (flat, not an untyped empty
  array, no index types). `event` and `thread_watch`: the same for `v`, and
  an `i64` id for the latter. `select`: exactly one type argument; it must
  be an enum, every variant must have exactly one field, the fields' types
  must be distinct and accepted by `qget<T>`, no field may be resizable
  (for now), and the timed form's argument is an `i64`; the result is `E`,
  with a second `bool` result for the timed form, as `qget<T>(ms)` sets up
  `lastcallrets`. Errors name the variant: "select<Work>: variant Io must
  hold exactly one field, the message it receives", "select<Work>: variants
  Data and Retry both receive Batch".
* **Codegen** (`codegen_builtins.h`): `QueueFor` for each new builtin;
  `EmitBuiltin` cases emitting §10; one `static GS_TLS uint32_t` per
  `select` site, beside the queue globals in `data`; the existing `B_QGET`
  copy-out paths reading `gs_qmsg` and calling `gs_qdone` instead of
  `free`; the variable-mode `select` through the bytes path of `B_QGET`.
  Phase 2 adds the copy elisions of §9.6 to `B_QPUT` and `B_QGET`.
  `usesthreads` is set by every new builtin, so the JIT refuses these
  programs as it refuses any program with queues today.
* **Runtime** (`runtime.h` declarations, `runtime_threads.h`): phase 1's
  thread records with inbox tables, main's record, the parker, waiter
  lists and claims, inbox close at a worker's end, watches, events and
  `gs_event_signal`; phase 2's segments, chunks, tickets and fast parker.
  `goose.h` declares `gs_event_signal`. New aborts: `GS_E_NOTHREAD`
  ("qput_to or thread_watch of a thread id never issued"), `GS_E_WATCH`
  ("thread_watch of main or of the current thread"), `GS_E_EVENT`
  ("event_close of an event this thread does not hold open"). The
  runtime's text changes, so `GS_RUNTIME_VERSION` changes and runtime
  objects are rebuilt; `runtime_inline.h` is regenerated with
  `goose --gen-runtime-header`.
* **Language server** (`lsp_features.h`): hover and signature help for the
  new builtins come from the builtin table; completion offers them.
* **No syntax.** `select<E>()` is a call with a type argument, as
  `qget<T>()` is; the parser, the formatter, the tree-sitter grammar and the
  Goose-in-Goose parser are unchanged.

## 12. Alternatives considered

* **`select` as a statement with arms** (`select { m: Morsel => …, after(10)
  => … }`, Go's form). It reads well, but it is new syntax for what a typed
  call and `match` already express, and its arms would not be values: a
  library could not wrap it, return its result, or keep it in a loop's
  state. The enum form is one builtin, and its result is an ordinary value.
* **A readiness wait** (`wait_any(sources, ms) -> index`, then `qpoll`),
  epoll's shape. It lets a message be reported ready and then taken by
  another thread, so every caller must loop, and it needs source values for
  types, which Goose does not have. `select` takes, so it never reports
  what it cannot deliver.
* **Event objects as a source of their own**, with `select` taking event
  ids beside types. That makes `select`'s sources partly runtime values,
  bound to variants by position or by an id in the payload, and gives a
  thread a second way to be woken. Delivering an event as a message keeps
  one way.
* **A per-thread signal word** (`gs_signal(thread, bits)`, kqueue's
  `EVFILT_USER` with `NOTE_FFOR`, Windows' `PostThreadMessage`): the
  thinnest C side, but independent libraries in one thread would have to
  share 64 bits by convention, and the program would still need a variant
  to receive it. Events give each library its own, as cheaply.
* **C posting typed messages** (`gs_post(thread, type, bytes, size)`): C
  would have to build a Goose value's bytes valid at their type and name a
  queue, and the messages could not merge. An event lets Goose build the
  value once.
* **Blocking puts with a timeout** (`qput_to(id, v, ms)`), so that a sender
  could wait for room. Any blocking put can deadlock an exchange whose
  workers send to each other (§4.4); credits give the sender a precise
  wake-up without it.
* **Inboxes only, no global queues for addressed types**, or `qget` reading
  only the global queue and a separate `qrecv<T>()` reading the inbox.
  Reading both in `qget` changes nothing for programs that address nothing,
  and gives affinity with stealing for free (§8.1); a separate builtin
  would double the takes and `select` would need both kinds of source.
* **Messages to an ended worker kept for a later reader, or returned to
  the global queue.** Nobody can read another thread's inbox, ids are
  never reused, and moving a message addressed to one thread into a queue
  any thread takes would deliver it where its sender did not send it.
* **Per-sender order only, for faster inboxes** (rings per sender). §4.5:
  a shared ticket costs 10 to 35 ns here, which does not pay for the
  weaker order.

## 13. Testing

Following `docs/testing.md`: positive fixtures with expected output, abort
fixtures with `.aborts` and `.stderr`, and rejections with `// error:`
markers. Threads run only natively, so the new fixtures, like
`threads/`'s today, run at `-O0` and `-O2` and are skipped by the JIT.

* `threads/inbox_basic.goose`: `thread_id()` on main (-1) and in workers;
  `qput_to` a worker and back to main; inbox before global for one type;
  a sender's order, and two senders' order when one's put returned before
  the other's started (a message chain); a thread's own inbox.
* `threads/inbox_limits.goose`: `qlimit` applying to each inbox and to the
  global queue separately; a full inbox refusing at once and accepting
  again after a take; one full inbox not refusing another; a lowered limit.
* `threads/inbox_ended.goose`: puts to a worker that returned and to a
  contained worker that aborted are `false`; messages left in its inbox are
  gone after `thread_wait`; `qput_to` to a worker before it first takes;
  a child's inbox outliving its parent.
* `threads/thread_watch.goose`: a watch on a running worker, on one that
  has ended (at once), several watches on one worker, a watch made by a
  worker that ends first (dropped); the report-before-end guarantee of
  §4.6; `thread_wait` returning at once after the watch message.
* `threads/select_basic.goose`: one thread, messages of three types put
  in an order; the rotation order `select` takes them in; the timed form's
  zero value and `false`; `select<E>(0)` and a negative `ms` not waiting;
  a generic `E`; a variable-mode `E..` with a string field.
* `threads/select_wait.goose`: workers sleeping in `select` woken by each
  of their types, from the inbox and from the global queue; many workers
  selecting on one global queue and their inboxes, every message taken
  exactly once (the claim protocol); a deadline that passes with nothing,
  within its time.
* `threads/event_signal.goose` with `event_signal.build` and
  `event_signal_impl.c`, a fixture with a sidecar, which the runner builds
  with `goose build`: C threads (pthreads, or `CreateThread` on Windows)
  signalling events of a worker and of main, before and during their waits;
  a burst of signals merging into one message; signals to a closed event
  and to an ended thread's returning 0; an event's message queued into a
  full inbox.
* `threads/exchange_credits.goose`: §8.2 at small scale, 4 workers and
  windows of 2, every row arriving once at its owner.
* `threads/reports_watched.goose`: §8.1's collection with one contained
  worker aborting, finishing without a hang and with the abort's message.
* `runtime/` abort fixtures: `qput_to_unknown.goose` (an id never issued),
  `thread_watch_self.goose`, `thread_watch_main.goose`,
  `event_close_foreign.goose`, `event_close_twice.goose`.
* `errors_tc/`: `select` with no type argument, with a struct, with a
  variant of no field and one of two fields, with two variants of one type,
  with a non-flat field, an index-typed field and a resizable field, with a
  non-integer `ms`; `qput_to` of a non-flat value, with a non-integer id;
  `event` and `thread_watch` of non-flat values.
* `threads/runtime_threads_lifecycle.c`: records recycled under worker
  churn with no growth in live allocations; inboxes discarded at a
  worker's end with their messages' memory; events closed with their
  owners, signalled from a foreign thread racing the owner's end; phase 2's
  segments and chunks recycled, with no allocation in steady state.
* The sanitize profile runs all of these, and phase 2 runs the lifecycle
  test and the `select`/exchange fixtures under ThreadSanitizer once by hand,
  since the suite has no TSan profile.
* `bench/queues.py --quick` builds and runs every mode in seconds; phase 2
  runs the full session for §9.8.

## 14. Documentation

* **Spec §11.2**: inboxes and `thread_id`, `qput_to`, the takes' inbox
  first, limits per queue, order (§4.5, stated for the first time), a worker's end and
  what it does to inboxes, events and watches, `thread_watch`, `select`
  and its rules, events and `gs_event_signal`. §12's builtin table gains
  the six builtins. Appendix B TODO 9 ("queue fairness/capacity, select")
  moves to Resolved, keeping its other items (worker-local init, sending
  self-contained relative-reference values).
* **Spec §7.10**: one paragraph naming `gs_event_signal` as the call C
  makes into the runtime, and that it may come from any thread.
* **Reference §22**: the builtins in its table; "Messages to one thread",
  with §8.1's report collection cut down; "Waiting for several things",
  with `select`; "Events from C", with §6.3's shim cut down.
* **`docs/implementation.md`** §6.8 (the `gs_qmsg` interface, `select`'s
  sites and arrays) and §7 (thread records and inboxes, the parker and
  claims, events; in phase 2 the segments, chunks and spinning).
* **`docs/packages.md`**, "The native part": `goose.h`'s `gs_event_signal`.
* **`docs/testing.md`**: the new fixtures in the `threads/` row.
* **`docs/index.md`**: this note among the design notes (done with it).
* **`bench/queues.md`**: phase 2 records its session beside the baseline.

## 15. The plan

Each step is one working commit with the suite green.

### Phase 1 (#5): addressed delivery and `select`

1. **Thread records.** Recycled `gs_thread` records with a table of
   inboxes (a `gs_qstate` per queue type, made on first use), main's
   record, a thread-local pointer to the caller's own; queue type numbers
   from `gs_qinit`; the id-to-record map. No behavior changes.
2. **The take interface.** `gs_qmsg` and `gs_qdone`, `gs_qget`/`gs_qwait`
   taking from the inbox first; codegen of `qget`/`qpoll`/`qget(ms)`
   switched to them. No behavior changes: inboxes stay empty.
3. **Waiting.** The per-thread parker (mutex, condition variable, state),
   waiter lists in each `gs_qstate` under its mutex, claims on put,
   claimed-queue-first on wake, absorbed spurious wake-ups; the condition
   variable per queue goes. `bench/queues.py` within 10% of §3.2.
4. **`thread_id` and `qput_to`**, with ended-worker refusal and
   never-issued aborts, inboxes closed and discarded at a worker's end
   before it is marked ended. Tests: `inbox_basic`, `inbox_limits`,
   `inbox_ended`, `qput_to_unknown`, the `qput_to` rejections.
5. **`thread_watch`.** Tests: `thread_watch`, `reports_watched`, the watch
   aborts.
6. **`select<E>`**, fixed and variable mode: checker rules, the site
   rotation, `gs_qselect`. Tests: `select_basic`, `select_wait`,
   `exchange_credits`, the `select` rejections.
7. **Events**: `event`, `event_close`, `gs_event_signal` with external
   linkage and in `goose.h`. Tests: `event_signal` with its C, the event
   aborts, the lifecycle test's foreign signals.
8. **Documentation** (§14), and `bench/queues.md` re-measured.

### Phase 2 (#6): queue performance

1. **The parker.** `futex`, `WaitOnAddress` and
   `os_sync_wait_on_address`, with phase 1's as the fallback; spin, then
   park, with `GS_QSPIN_NS` measured; a put's parked-count check after a
   fence. Measure `rt2` and `tput` 1 × 16.
2. **Segments and tickets**, with inline payloads up to 48 bytes, exact
   limits, inboxes closed and reused through the generation in `tail`;
   `gs_qstate` replaced. Measure `drain` and `tput` 16 B.
3. **Chunks** for payloads over 48 bytes, and segments, chunks and event
   and watch records on free lists. Measure 32 KB; no `malloc` per message
   (a counting allocator in the lifecycle test).
4. **Copies**: `qput` from the lvalue, takes into the destination (§9.6).
5. **Inbox lookup** through the per-thread cache (§9.7).
6. **§9.8's targets** on this workspace, the session recorded in
   `bench/queues.md`, `docs/implementation.md` §7 updated.

## 16. Open questions

Each with the answer this note recommends.

* **Should `qput_to` to an ended worker return `true`, discarding the
  message, so that a retry loop cannot spin on a dead receiver?** No: keep
  `false`, one meaning for the result, and tell retrying senders to watch
  their receivers (§4.3). Revisit if real protocols get this wrong.
* **Should a thread set its own inbox's limit apart from the type's?** No:
  a type per role (§4.4).
* **Should `select` be able to wait for room in another thread's inbox?**
  No: credits give the same wake-up with a message, and a sender that
  waits for room in a receiver that waits for room in it would deadlock
  (§4.4).
* **File-descriptor events (`event_fd(fd, v)`)?** Not in phase 1 (§6.4).
  Add them when a library's completions cannot be bridged by a thread of
  its own at acceptable cost: io_uring at very high completion rates is
  the likely first.
* **`gs_event_signal` from a signal handler?** Not promised: in phase 1 it
  takes the inbox's mutex, and in phase 2 a put can take the segment free
  list's mutex, once in 64 messages. If a user needs it, an event can keep
  a slot of its own in its inbox, so that signalling it never takes a lock
  or a segment.
* **Should `qget` take from the global queue now and then even when the
  inbox has messages, as Go's scheduler does every 61st time?** No: inbox
  first is a rule a program can rely on (§5.3).
* **A `biased` `select` that checks variants in declaration order?** No,
  until a program shows that `qpoll` first is not enough (§5.3).
* **Batched `qput_n`/`qget_n`?** Not in phase 2: §3.3 shows the
  per-message costs a batch saves are tens of nanoseconds, against the
  microseconds of locks, wake-ups and allocation that phase 2 removes.
  Measure again after phase 2.
* **A deadline in nanoseconds (`select_until<E>(deadline_ns)`)?** No:
  milliseconds, as `qget(ms)`; a coroutine loop's timers round up to the
  next millisecond. Revisit with a loop that needs finer timers.
* **Resizable fields in `select`?** Later, when a program receives
  `u8[>..]` messages through `select`; `qget` takes them today.
* **The spin before parking: fixed or adaptive?** Fixed per platform and
  measured (`GS_QSPIN_NS`), overridable at compile time; an adaptive
  bound (spin as long as recent waits were short) after phase 2 if
  workloads differ.
* **Main as -1, or workers numbered from 1 and main 0?** -1: existing ids
  stay what they are.
* **A non-blocking "has this worker ended" query?** No: `thread_watch`
  answers it with a message, which composes with `select`.
* **Should `trim_memory()` return the queues' free chunks and segments to
  the system?** Yes, the caller's and those on the free lists, in phase 2:
  a thread that queued a burst of large messages can then release it.
* **Should more-fast-db keep workers across runs** (its bottleneck 1)?
  Outside this note, but inboxes make it straightforward: a pool of workers
  each waiting in `select` for a run's `Args` in its inbox.

## References

Spec: [§3.4 placement](../goose_spec.md#34-placement-rules-what-may-contain-what),
[§3.5 ADTs](../goose_spec.md#35-algebraic-data-types),
[§4.3 in-place construction](../goose_spec.md#43-the-in-place-construction-guarantee),
[§7.10 `extern fn`](../goose_spec.md#710-extern-fn),
[§9.3 runtime checks](../goose_spec.md#93-what-the-runtime-still-checks),
[§11.2 concurrency](../goose_spec.md#112-concurrency),
[Appendix B](../goose_spec.md#appendix-b-todo--open-items) (TODO 9);
[implementation.md §6.8](../implementation.md#68-threads-and-queues),
[§7 the runtime](../implementation.md#7-the-runtime);
[testing.md](../testing.md);
[coroutines.md](coroutines.md),
[owning_dynamic_data.md](owning_dynamic_data.md) (option C),
[dynamic_externs.md](dynamic_externs.md);
[bench/queues.md](../../bench/queues.md).

* D. Vyukov, [Bounded MPMC queue](https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue): a slot per ticket with a sequence number.
* crossbeam, [`SegQueue`](https://docs.rs/crossbeam-queue/latest/crossbeam_queue/struct.SegQueue.html): an unbounded lock-free MPMC queue of linked blocks of slots.
* M. Michael and M. Scott, [Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms](https://www.cs.rochester.edu/~scott/papers/1996_PODC_queues.pdf), PODC 1996: the two-lock queue.
* A. Morrison and Y. Afek, [Fast Concurrent Queues for x86 Processors](https://www.cs.tau.ac.il/~mad/publications/ppopp2013-x86queues.pdf), PPoPP 2013 (LCRQ): rings claimed with fetch-and-add, closed by a bit in the tail.
* Go, [`select` statements](https://go.dev/ref/spec#Select_statements) and the runtime's [`schedule`](https://github.com/golang/go/blob/master/src/runtime/proc.go) (the global run queue every 61st tick).
* tokio, [`select!`](https://docs.rs/tokio/latest/tokio/macro.select.html): random by default, `biased;` in order.
* Erlang, [processes and message passing](https://www.erlang.org/doc/system/ref_man_processes.html): mailboxes per process, ordering per pair of processes.
* libuv, [`uv_async_t`](https://docs.libuv.org/en/v1.x/async.html): a wake-up from any thread, merged while pending.
* Linux, [`eventfd(2)`](https://man7.org/linux/man-pages/man2/eventfd.2.html) and [`futex(2)`](https://man7.org/linux/man-pages/man2/futex.2.html); FreeBSD, [`kqueue(2)`](https://man.freebsd.org/cgi/man.cgi?kqueue) (`EVFILT_USER`).
