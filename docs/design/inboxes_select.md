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
* **Limits, purely additive.** `qlimit<T>(n)` keeps exactly today's
  meaning, the limit of `T`'s global queue, so no existing program changes
  meaning. A new `qlimit_inbox<T>(n)` limits every thread's inbox of `T`,
  each on its own. A put to a full inbox is refused at once, as a put to a
  full queue is today; nothing blocks. Backpressure between workers is a
  protocol of credits, which `select` makes cheap (§4.4, §8.2).
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
* **Events from C are messages.** `event(v) -> resource<event>` makes an
  event that belongs to the calling thread; its handle is option C's
  opaque `resource<U>` as `shared_memory.md` §4.1 specifies it, one `u64`
  that no program can make up or compare, and a `uint64_t` in C. C calls
  `gs_event_signal(e)` from any thread, Goose's or not, and a copy of `v`
  is pending in the owner's inbox, where `qget` and `select` find it like
  any other message; signals that come while it is pending are merged into
  it, no signal returns before its copy can be found, and a stale or
  invalid handle is reported to C, not acted on. The runtime
  therefore wakes a thread only by giving it a message, and `select` needs
  no source but typed queues and a deadline (§6).
* **Coroutines.** coroutines.md makes `select` and channels libraries over
  coroutines. The one runtime primitive such a library needs is the
  thread-level wait: block this thread until a message of one of these
  types arrives or a deadline passes, take it, and say which. That is
  `select<E>(ms)`. Everything inside one thread stays in the library, and
  flat frames travel between workers with `qput_to` (§7).
* **Faster queues, without new surface.** Phase 2 changes the runtime, and
  removes two copies from the generated code: each queue becomes a ring of
  slots in recycled segments, and a put claims its slot and publishes its
  message in one double-width compare-exchange, so a take never finds a
  half-made message and never waits for a put, whatever the putter's
  thread is doing. A message of up to 8 bytes travels in its slot, a larger
  one in a chunk that the sending thread fills and that is recycled when
  its last message is taken. Waiting threads spin briefly, then park on a
  word of their own; a put wakes a thread only if one is parked. A value is
  copied once in and once out (§9). No batched API: §3 shows the
  per-message cost is not where the time goes.
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
  increment however many of the 16 cores contend for it, and a
  compare-exchange loop costs about 35 ns, so a queue whose puts and takes
  are one atomic operation each on a shared line can serve tens of
  millions of messages a second. A message between two
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
streams between any threads are today. The id stays the integer it is:
`thread_spawn` returns it and `thread_wait` takes it today, so changing
its type would change existing programs, and an id a program computes
names a thread that any thread may address anyway, or aborts as one never
issued (§4.3). An event's handle is different, since it lets C deliver a
particular thread's message, and is a `resource<event>` (§6).

**Channel handles** would add a kind of value: a flat `chan<T>` naming a
queue, created by a thread and copied into messages and spawn arguments.
Each question inboxes answer by construction would need an answer of its
own. Who may take from a channel: only its creator (then it is an inbox
with a second name), or anyone holding it (then it is a global queue with a
name, and its taking threads must be told apart again). When it is freed:
with its creator (then every copy is a dangling handle, which needs a
generation check: the never-reused id inboxes already have), or explicitly
(then a program can free a channel others still hold). Option C's
`resource<U>` (`owning_dynamic_data.md`; step 0 of `shared_memory.md`)
would keep a program from making a channel up out of an integer, as it
does for events (§6); it would not answer those questions.
What channels add over inboxes is several queues of one type per thread,
which a wrapper type gives (`struct ToJoin { b: Batch }`), and queues that
are not tied to a thread, which the global queues are. The engine needs
neither.

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

`qlimit<T>(n)` keeps exactly today's meaning: it limits `T`'s global queue
and nothing else, so no program changes meaning. Inboxes have a builtin of
their own, `qlimit_inbox<T>(n)`, which limits every thread's inbox of `T`,
each holding at most `n` messages of its own. Like `qlimit`, it applies to
the whole program, an inbox has no limit until it is called, a limit of
zero or less aborts, and lowering a limit keeps what is queued. A
`qput_to` to a full inbox is refused at once, as a `qput` to a full global
queue is, and a full inbox at one worker refuses nothing to another.

The form is the type's, not the thread's, for three reasons. It mirrors
`qlimit`, one count per type, so the two read as siblings and a program
sets each where it sets the other. It can be set once, by main, before any
worker exists, so it holds for every inbox from its first message; a limit
that each thread set on its own inbox would leave the time between a
worker's spawn and its first statement unbounded, which is when a spawner
sends the most. And the engine wants the same bound at every receiver. A
program that wants two bounds for one payload has two types (`struct ToJoin
{ b: Batch }`), as for anything else that has to be told apart; a form per
destination is an open question (§16). A watch's message (§4.6) is queued
even into a full inbox, since refusing it would lose it; it counts while it
waits, so puts are refused until the inbox is below its limit again. An
event's pending copy is not queued at all, and counts against nothing
(§6.1).

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
Between types, `select`'s rotation decides (§5.3). An event's pending copy
has no place in an inbox's order either: it is a mark that the inbox's takes
look for, taken by turns with its queued messages (§6.1), since a signal
from C is ordered with nothing a Goose thread puts. A protocol that needs an
order between two kinds of message sends them as one type, an enum, or puts
the order in the messages (the exchange's last batch of §8.2 carries its own
end-of-stream mark rather than following it with a message of another type).

Phase 2 keeps this exactly: one queue's puts are ordered by the slots
they claim, and a slot is claimed and filled in one atomic step (§9.3).
Per-sender order alone would have allowed rings per sender, but would let
a message overtake one that was put before it by another thread; §3.3
shows that claiming a shared slot costs about 35 ns under contention, which
is not worth that.

### 4.6 When a worker ends

A worker ends by returning, or by an abort if it is contained. The runtime
then, in this order:

1. releases its storage, as today;
2. closes its inboxes: later `qput_to`s to it are refused, and the
   messages left in them are discarded, never taken by anyone; closes its
   events, so that later signals return 0, and discards their pending
   copies (§6); and cancels the watches it made;
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

The deadline is not a source that takes its turn in the rotation: when a
message is waiting, `select` returns it, whatever its timeout, and a
timeout of zero or less only makes it a poll. So a `select` whose types
never run dry never times out, and a loop that keeps timers must check
them itself on every turn, not only when `select` misses (§7.2).

### 5.3 Fairness and starvation

A `select` checks its sources in a rotation that each call site keeps for
each thread: it starts at the variant after the one that site returned
last, and takes the first message it finds. A type that has a message is
therefore taken within as many calls of that site as `E` has variants,
however much the other types receive: no type starves another. The
rotation is deterministic, so a program that sees the same messages in the
same order selects them in the same order, which a random choice (Go's,
tokio's by default) would not give.

Within one type, the inbox comes before the global queue (§4.5), and
within the inbox, its events' pending copies and its queued messages are
taken by turns (§6.1). A wake-up changes none of this: a thread woken by a
put to one of its queues takes as any take does, whichever queue woke it
(§9.5). A thread
whose inbox for `T` never empties never takes `T` from the global queue:
that is the point of addressing. Go's scheduler takes from its global run
queue every 61st time to avoid exactly this, which trades the starvation
for a rule a program cannot see; here the rule is the one the program
wrote. §16 keeps the question.

A program that wants priority asks for it: it `qpoll`s the urgent type
first and then `select`s, or puts the urgent kind and the rest in separate
`select`s. A `biased` form that checks variants in declaration order is
deferred until a program needs it (§16).

When a `select` that slept is woken, it takes the first message in its
rotation, as any call does, and if it leaves a message on a queue on which
other threads sleep, it wakes one of them in turn (§9.5): a message that
wakes a thread is never left behind with its takers asleep, whichever
source the woken thread takes from.

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
own condition variable. In phase 2 a check is, for each of the two queues
of a variant, a load of `head` and one of the slot it names, from cache
lines that stay in the caller's cache while nobody writes them, a few
nanoseconds; a check never waits for a put in progress, since no slot is
ever half filled (§9.3). Then the thread spins, rechecking, for about the
time a wake-up costs (§9.5), and only then parks. A sleeping thread is woken by
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

let done = event(IoDone { worker: 3 });   // a resource<event>, for C
shim_read_async(fd, offset, length, tag, done);
// ... and when C has signalled it, IoDone { worker: 3 } is in the inbox:
match select<Work>() {
    Io d => reap_reads(),
    _ => {},
}
event_close(done);
```

* `event(v) -> resource<event>` makes an event belonging to the calling
  thread and holding a copy of `v`, a flat value. The handle is option C's
  opaque `resource<U>` (`owning_dynamic_data.md`) as [`shared_memory.md`
  §4.1](shared_memory.md#41-resourceu-the-first-step) specifies it, step 0
  of that note's plan, which both tracks build on: a single `u64` that a
  program can copy, store, put in a message and pass to an `extern fn`, but
  cannot compare, compute with or make from an integer, so the only handles
  a program holds are ones the runtime handed out. `event` is a kind the
  runtime provides, beside that note's `shared`, `mapping` and `frozen<T>`;
  in its table of kinds it is made by `event` and taken by `event_close`
  and, in C, by `gs_event_signal`. Like every kind, its default is the zero
  handle, which names nothing, and its text form is its type alone.
* Signalling `e` while it is open makes a copy of `v` **pending** in its
  owner's inbox for `v`'s type, unless one is pending already. While one
  is, further signals merge into it; once the owner has taken it, the next
  signal makes a new one pending. A signal therefore wakes the owner at
  least once after it was made, and a burst of signals wakes it once. A
  signal returns only once its copy, or the one it merged into, can be
  taken, and the owner has been woken for it if it waits (§6.2).
* To the owner, a pending copy is in its inbox: `qget<V>`, `qpoll<V>` and
  `select` take it there, before `V`'s global queue. It is not queued among
  the inbox's messages, though: it has no place in their order (§4.5), it
  does not count against `qlimit_inbox` (§4.4), and the owner's takes of
  `V` from its inbox take, by turns, a pending copy and a queued message, so
  that neither keeps the other waiting.
* `event_close(e)` closes an event of the calling thread: later signals
  are ignored, and a copy already pending stays to be taken. Closing an
  event of another thread, one that is closed already, or the zero handle
  aborts. A thread's events close when it ends, and their pending copies
  are discarded with its inboxes (§4.6).

An event carries no data beyond `v`, which is fixed when it is made: what
happened is the C library's to say when the thread asks it (`reap_reads`
calls an `extern fn` that hands back the completed reads), and a thread
that wants to tell sources apart makes an event for each, with a `v` of
its own; it never needs to compare two handles. This is the shape of an
eventfd, of libuv's `uv_async_t` and of an io_uring completion queue: the
signal says "look", and is merged while nobody has looked; the data waits
where the library keeps it.

### 6.2 The C side

A `resource<U>` crosses the C boundary (§7.10) as the 64-bit word it is,
`gs_res`, a `uint64_t`: a `resource<event>` parameter of an `extern fn` is
one. As for every kind of the runtime's, C may take an event's handle but
never return one, nor a value holding one (`shared_memory.md` §4.1), so no
C function hands Goose a handle that the runtime did not make. C may keep
the word as long as it likes, since it is a name, not a pointer, and gives
it back to the runtime:

```c
#include "goose.h"

/* Signals the event `e`: a copy of its message becomes pending in its
   thread's inbox, unless one is pending already, and the thread is woken if
   it waits. Returns 1 once a copy is pending and can be taken, whether this
   call made it pending or merged into one; 0 when `e` named an event that
   is closed now, by event_close or by its thread's end; -1 when `e` never
   named an event: the zero handle, or a word the runtime never handed out. */
int gs_event_signal(gs_res e);
```

* **What the word holds.** Bits 63 to 24 are the record's serial and bits 23
  to 0 the index of the event's record in the runtime's table of events, the
  split that `GS_RES_SERIAL_BITS` and `GS_RES_REGION_BITS` name for every
  kind of the runtime's. A record's serial grows by one each time the record
  holds a new event and is never reused: a record whose serial reaches 2^40
  - 1 is retired rather than used again. So no word ever names two events,
  however long a C library keeps a stale one, and the zero word (serial 0,
  which no record has) names none. The split is checked where handles are
  made: at most 2^24 event records are in use at once (a record is in use
  from `event` until the event is closed and no copy of its message is
  pending, below), and `event` aborts beyond that ("too many open events").
* **Stale or invalid.** The table is never shrunk or freed while the
  program runs, so the call can always read the record at the word's index
  (an index past the table's end is -1 at once). The record's state word
  holds its current serial beside its state. The word's serial equal to it,
  with the event open, is a signal (1). A smaller one, or the same one with
  the event closed, is a stale handle (0): every serial below the current
  one was handed out once, since serials grow by one. A larger one, or 0,
  was never handed out (-1). The runtime reports neither itself: a library
  may legitimately race an event's close, and only the library can tell
  whether a word it holds is garbage, so it is told which, and decides.
* **Any thread, any time.** A Goose thread or one the C library started,
  before the owner first waits, while it waits or while it runs, and after
  it has ended or closed the event, which returns 0, so a C library that
  outlives its user's interest needs no handshake to stop.
* **Pending, and findable.** A record holds the event's state word (its
  serial; whether it is open; whether a copy is **pending**), its message
  `v`, and the place of its **hint**: one bit, in a word of its owner's
  inbox for `v`'s type, that tells the inbox's takes to look at the
  record. A signal makes the copy pending with one compare-exchange of the
  state word from (its serial, open, not pending) to (its serial, open,
  pending), which checks in the same step that the record is still the
  event `e` names and that it is open; a signal that finds a copy pending
  already has merged, and changes nothing there. Either way, the signal
  then sets the hint bit with one atomic `or` and, after a full fence,
  wakes the owner if it is parked, as a put does (§9.5); only then does it
  return 1. So a signal that merges into a copy whose own signal stopped
  between its compare-exchange and its hint does that signal's remaining
  work itself, and no signal reports a copy that the owner cannot find, or
  has not been woken for, whatever the thread that made it pending is
  doing. Setting a bit that is set changes nothing, and claiming a parked
  thread that is claimed already does nothing (§9.5), so this help makes
  no second copy and no second wake-up. The stopped signal, once it
  resumes, sets a bit that means nothing by then, or wakes its owner once
  for nothing.
* **Taking it.** The owner's take clears a hint bit it finds set, with an
  atomic `and`, and only then clears the record's `pending`, with a
  compare-exchange from (the serial the owner gave that bit, pending), and
  copies the message out. In that order, a signal that comes between the
  two sets the bit again, so no pending copy is ever without its hint; and
  a signal that comes once the copy is taken, while the owner handles it,
  makes a new one pending. A bit whose record has nothing pending (a hint
  that came late, or one for a record since reused) is passed over: a hint
  is only a reason to look, and the state word decides.
* **Thread-safe by construction.** A signal shares no state with Goose code
  beyond the record and its hint word, runs no Goose code, and allocates
  nothing (the pending copy is the record). In phase 2 it takes no lock on
  Linux, Windows or macOS, since waking a parked owner takes none there
  (§9.5); in phase 1 it takes the mutexes that a put takes to wake a thread.
  Hint words are kept with their thread's record, in blocks that are never
  freed while the program runs, so a signal that stopped holding the place
  of one writes, when it resumes, into memory that is still a hint word.
  Both phases use the same records and hints.
* **Close, reuse and signals in flight.** `pending` keeps a record from
  being reused under its copy. A record goes back to its free list only
  once its event is closed and no copy is pending, and the thread that
  makes that so returns it, which is always the owner: `event_close` of an
  event with no copy pending; the take of a closed event's copy, once the
  copy has been handed over (`gs_qdone`, §10); or, at the owner's end, the
  discard of its events' pending copies. So:
  * a pending copy always carries its own event's message, since its
    record cannot hold another event until the copy is taken or discarded;
  * a signal that made a copy pending before `event_close` has it taken
    after the close, with the closed event's message (§6.1), even if it
    stopped before setting its hint: `event_close` that finds a copy
    pending sets the hint itself, since a signal that starts after the
    close finds the record closed and returns 0 without touching it;
  * closing an event and making another before the closed one's copy is
    taken gives the new event another record and another hint bit, and
    both copies are taken, each with its own message;
  * a signal that made a copy pending before its owner ended returns 1, as
    a message put to a worker that then ends is `true` (§4.6), and its copy
    is discarded with the inbox. If it stopped before setting its hint, the
    bit it sets when it resumes lands in a hint word of that thread record,
    which a later owner checks against its own records as it checks every
    hint: it can make that owner look, or wake it once, and nothing more.
* **Not from a signal handler**: phase 1 wakes a parked owner through a
  mutex and a condition variable, which a handler may not touch (§16).
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
   the shim's own, under its own lock; a job keeps its event's word. */
struct job { int64_t fd, offset, length, tag, result; gs_res done; void *buf; };

bool shim_read_async(int64_t fd, int64_t offset, int64_t length, int64_t tag,
                     gs_res done);                       /* queues a job */

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
extern fn shim_read_async(fd: i64, offset: i64, length: i64, tag: i64, done: resource<event>) -> bool;
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

* **No callbacks.** C signals an event by its handle, and the runtime gives
  the loop a message; nothing calls into Goose code, and the loop decides
  what to resume, as coroutines.md §2.7 wants.
* **Zero cost otherwise.** A program without `qput_to`, `select`, events
  or watches runs its queues as it does today; the inbox check in a `qget`
  costs a test of an inbox nobody has made in phase 1, and in phase 2 a
  load of the inbox's `head` and one of its slot, lines that stay in the
  caller's cache (§9.3).
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
        fire_due_timers();                       // every turn: a flood of messages must not starve them
        run_ready_tasks();                       // resume(...) each runnable frame to its next yield
        let m, got = select<LoopMsg>(ms_until_next_timer());   // 0 when a timer is due
        guard got else { continue; }             // the deadline passed: the next turn fires it
        match m {
            Reply r => wake(r.r.tag, Woke.Value { v: r.r.v }),
            Io d => {
                for c in reactor_completions(d.d.ring) { wake(c.tag, Woke.Done { bytes: c.bytes }); }
            },
        }
    }
}
```

The loop fires due timers at the top of every turn, not only when `select`
times out: with messages always waiting, `select` returns one on every
call, even with a zero timeout (§5.2), so a loop that fired timers only on
a miss would never fire them while its inbox was busy. One message per
turn also keeps a busy inbox from delaying a timer by more than a turn.
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
  once (§3.4), and 1.5 µs in a Q1 run. In phase 2 a take is a
  compare-exchange and a copy from a slot: about 100 ns when takes do not
  collide, and at most
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
  sender: 16 × 8 × 32 KB = 4 MB per worker at 16 workers.
  `qlimit_inbox<Batch>` can stay unset; with credits, a refusal can only
  mean the receiver ended.
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
copies of a fixed-size message where two are needed. Phase 2 removes each,
without changing anything a program can observe: each queue first in, first
out (§4.5), exact limits, `qput` never blocking, inbox before global, the
zero values of misses, and the deadlines of `qget(ms)` and `select(ms)`.

### 9.2 Options

| option | no `malloc` per message | no lock for all | keeps §4.5's order | verdict |
|---|---|---|---|---|
| node pool behind today's lock | yes | no | yes | half the problem; the lock is §3's biggest cost |
| two locks, one for putters, one for takers (Michael and Scott) | with a pool | takers still share one | yes | 16 takers still collide (`drain`) |
| rings per sender (SPSC), takers scan them | yes | yes | per sender only | fastest for an exchange, but gives up §4.5, and a global queue has many takers per ring |
| sharded queues, a sender's shard by its id | with a pool | mostly | per sender only | the same loss, and takers scan shards |
| a ticket per put (`fetch_add`), its slot filled after (Vyukov's bounded queue, CRQ) | yes | yes | not with exact limits | a taker that reaches a ticket before its slot is filled must wait for the put, or kill the ticket (below) |
| one ring per queue whose slot a put claims and fills in one double-width compare-exchange, a compare-exchange to take, slots in recycled segments | yes | yes | yes | **chosen** |
| batched `qput_n`/`qget_n` | no | no | yes | saves what §3.3 shows costs least; a later addition if measured (§16) |

The chosen queue is the array queue of Tsigas and Zhang, and of Shann,
Huang and Chen, in which a put claims the slot at the tail and publishes
its value in one compare-exchange, so that no slot is ever half filled;
made unbounded with linked segments of slots, as crossbeam's `SegQueue`
is. It differs from them in four ways: segments are recycled and never
unmapped, so a reader holding a stale pointer reads valid memory; limits
are exact; a slot's empty state carries its queue's incarnation, so that a
put meant for one queue can never fill another's slot; and a message of
more than 8 bytes lives in the sender's chunk, its slot holding its
address.

The ticket queues are the faster family on paper (one `fetch_add` per
put, 10 ns here against about 35 for a compare-exchange), but they leave a
moment between a put's ticket and its value. A taker that reaches the
ticket in that moment either reports the queue empty, as Vyukov's queue
does, though a message whose put has returned may be waiting behind it;
or waits for the put, as crossbeam's `ArrayQueue` does, which lets a
descheduled putter stall a `qpoll`, a `select(0)` or a deadline; or kills
the ticket and makes the put start over behind it, as Morrison and Afek's
CRQ does. Killing keeps polls and
deadlines, but not exact limits: a refusal that counted the stopped put's
ticket would have counted a message that is then queued behind later
ones, which no first-in, first-out queue can explain. Claiming and filling
at once leaves no such moment.

### 9.3 The queue: slots claimed and filled at once

A queue (a type's global queue, or one thread's inbox for a type) holds
two counters, `tail` (the next slot to fill) and `head` (the next to
take), on cache lines of their own, and a chain of segments of 64 slots:
slot `t` is slot `t % 64` of the segment whose first ticket is `t - t %
64`. A slot is 16 bytes: a state word, which names the slot's ticket and
says whether the slot is empty, full or closed (`(t + 1) << 2 | kind`, so
that zero is no state), and a value word, which holds the queue's
incarnation (below) while the slot is empty and the message once it is
full: the message itself when it has at most 8 bytes, its address
otherwise (§9.4). The counters never wrap: 2^62 tickets would take more
than a century at a billion a second.

* **Put.** A put to an inbox first checks the inbox's owner (below). The
  putter reads `tail`, `t`, and for a limited queue `head`, `h`: when `t -
  h` is at least the limit, the queue holds that many messages, and the put
  is refused. Otherwise it claims slot `t` with one double-width
  compare-exchange (`cmpxchg16b` on x86-64; `casp`, or an `ldxp`/`stxp`
  loop, on AArch64: Goose's two native targets) from (empty `t`, the queue's
  incarnation) to (full `t`, the message), which publishes the message in
  the same instant, and then moves `tail` from `t` to `t + 1`. Finding the
  slot full, it moves `tail` on for whoever filled it and tries again; a
  slot keeps its full state after its message is taken, until its segment is
  recycled, so a putter can do this even when takers have already passed the
  slot, and `tail` may lag behind `head` by the slot of a put that stopped
  before moving it (`t - h` is then negative, and refuses nothing). The
  claim is the put's moment: a refusal is a moment the queue held its limit
  (`head` only grows, so `t - h` never overstates what the queue held when
  `h` was read), a claim is a moment it held less, so the limit is exact,
  and messages are taken in the order of their slots. After a full fence the
  putter reads the queue's count of parked threads; if it is zero, which is
  the common case, the put is done (§9.5).
* **Segments.** A thread that needs a segment past the last links one
  with a double-width compare-exchange of the last segment's `next` and
  the **generation** beside it, a count of that segment's reuses that grows
  by one each time the segment goes back to a free list and is never
  reset. Both live in the segment's **header**, with its queue's
  incarnation, its first ticket, its count and its link in a free list,
  in a table of headers kept apart from the slots, which no trim discards
  (§9.4). The linker reads the parent's generation, then the incarnation and
  first ticket in its header, then its generation again, as a sequence
  lock is read; it gives its new segment the next first ticket, and links
  it only if the parent's generation is still the one it read. A linker
  that stops after reading the parent, while the parent is finished,
  recycled and reused, in another queue or in its own at a later ticket
  with the same incarnation, finds another generation and starts again
  from the queue's header, rather than linking a segment of the wrong
  tickets. A thread that loses the race gives its segment back. Segments
  and chunks come from free lists that take no lock (§9.4).
* **Take.** A taker reads `head`, `h`, and slot `h`. Full: a
  compare-exchange of `head` from `h` to `h + 1` makes the message its own,
  and only the winner reads it. Empty, with the queue's incarnation, or no
  segment for `h` yet: the queue is empty, since a slot is filled only once
  the slot before it is. No slot is ever half filled, so a take never waits
  for a put, whatever the putter's thread is doing: a `qpoll` and a
  `select(0)` answer at once, a timed take returns at its deadline, and a
  `select` that finds a source empty goes on to its next.
* **Nothing waits for a stopped thread.** A put that stops before its claim
  holds nothing. One that stops after its claim and before moving `tail`
  holds nothing either: the next putter moves `tail` for it, and takers
  never read `tail`; until then, the segment `tail` is in stays where that
  putter can find it (Done, below). A thread that stops while linking a
  segment holds only the segment in its hand. A waker that stops in its scan
  of a queue's waiters delays only its own wake-up, since waking and
  registering take no lock (§9.5). So, on the systems Goose supports, no
  take, no put and no wake-up waits for a thread that was descheduled in the
  middle of an operation.
* **Done.** After the generated code has copied a message out, its slot
  is finished. A segment goes back to its free list once its 64 slots are
  finished and `tail` has passed it. Its count covers both: each finished
  slot adds one, and so does the compare-exchange that moves `tail` past
  its last slot, which only one thread makes, and whoever brings the count
  to 65 returns the segment. Finished slots alone would not do: a put that
  stops after claiming a segment's last slot and before moving `tail`
  leaves `tail` in that segment, and the putters that come next need that
  slot's full state to move `tail` on, after its message has been taken
  and finished. Going back bumps the segment's generation and clears its
  `next` in one compare-exchange. Each segment records its queue's
  incarnation and its first ticket, and a reader that followed a pointer
  to a segment checks them before and after it reads a slot: a reader
  holding a pointer to a segment that has since been recycled, even into
  another queue at the same tickets, sees that it is not the segment it
  wanted and starts again from the queue's header.
* **Close and reuse.** Every queue has an **incarnation**, a 64-bit number
  from a counter that the runtime never resets: a global queue one for the
  whole run, an inbox a new one each time its record gets a new owner. An
  inbox's header holds the owner's thread id beside its incarnation, and
  is read as a sequence lock is (incarnation, owner, incarnation again,
  where a new owner's incarnation is written before its id), so that a
  sender never pairs one owner with another's incarnation. A sender reads
  the pair, refuses if the owner is not the thread it addresses, and claims
  with the incarnation it read, so it can only ever fill a slot of that
  owner's inbox. A thread's end (§4.6) seals its inboxes: it marks the
  last segment's `next`, and every empty slot from the tail on, closed (one
  compare-exchange each, for the few slots of one or two segments; a put
  racing it either fills its slot first, and is discarded with the rest,
  or finds no empty slot), counting each closed slot as finished and
  moving `tail` over them as a put does, so that every segment still sees
  `tail` pass once, sets the owner to -2, which no thread has, and
  discards what is queued. A record reused for a
  later thread starts its inboxes anew, with a new incarnation and a fresh
  segment from the next ticket on. A sender that read worker X's pair and
  stopped before its claim, while X ended and its record went to Y (once,
  or seventy thousand times), finds no slot carrying X's incarnation and,
  reading the pair again, is refused, as for any ended worker. Incarnations
  never repeat (2^64 of them would take centuries at a billion new owners
  a second), so there is no generation to wrap or to run out of.
* **Inbox first.** A take of `T` looks at the caller's inbox for `T` (a
  load of `head` and of its slot, lines that stay in the caller's cache
  while nobody addresses it, and of its hint words if it has events of `T`,
  by turns with the slots, §6.2) and then the global queue.

The contended operations are one double-width compare-exchange per put and
one compare-exchange per take, plus, for a message in a chunk, a decrement
of the chunk's count: about 35, 35 and 10 ns on this machine with 16
threads at them (§3.3), against the microseconds a contended lock costs.
Phase 1 has no half-filled slots either, since its puts link a whole node
under the queue's mutex; but like today's queues, a phase 1 take waits for
that mutex while another thread holds it to link or unlink a node, however
long that thread is descheduled, which is what phase 2 removes.

**Nothing comes round.** Memory is reused, segments, chunks and records
alike, so a thread that stops between reading a word and changing it with
a compare-exchange may find the word holding its old bits for another
reason. Every such word carries, beside what it says, a number that never
comes back to an old value while the program runs:

| word | changed by | carries | why it cannot come round |
|---|---|---|---|
| a slot's state and value | a claim; a seal | the slot's ticket, and the queue's incarnation | tickets never repeat in a queue, nor incarnations in a run |
| `tail`, `head` | putters; takers | the counter itself | it only grows |
| a segment's `next` and generation | a link; a seal; the return to a free list | the generation, in a header that no trim discards | it grows at every reuse of the segment, and nothing resets it |
| a free list's top and count | taking and returning | the count | it grows at every change |
| an inbox's owner and incarnation | a thread's start and end | the incarnation, read as a sequence lock | incarnations never repeat |
| an event record's state | a signal; `event_close`; a take or discard of its message (§6.2) | the record's serial | it grows at every reuse, and a record whose serial is used up is retired |
| a parker's state (§9.5) | its thread's waits; a claim | the thread's count of waits | it grows at every wait |

The counters are 62 or 64 bits wide, more than any run can count to, except
an event record's serial, which is 40 bits so that a handle fits in one
`u64` with its index (§6.2), and whose record retires when it is used up.
Three kinds of word change without a compare-exchange: event hints, by
`or` and `and`; the counts of chunks and segments, by increment and
decrement; and waiter entries, which only their own thread writes (§9.5).
None compares anything that could have come round: a hint is only a reason
to look at a record, whose state word decides (§6.2), a count is brought to
its end by exactly one thread, and a waiter entry is only a reason to try
a claim, which its thread's parker decides.

### 9.4 Payloads: in the slot, or in the sender's chunks

* A message of up to 8 bytes travels in its slot's value word: a morsel,
  a credit, a control message, an `IoDone`.
* A larger one is copied, before the claim, into the sending thread's
  current **chunk**, 256 KB taken by bumping an offset, and the slot holds
  its address. A chunk counts the messages in it that have not been taken,
  plus one while it is a thread's current chunk; the taker's done
  decrements it, and whoever brings it to zero puts the chunk on the free
  list. A message larger than 64 KB gets a chunk of its own, rounded up to
  a multiple of 64 KB and kept on a free list by size.
* A watch's message (§4.6) is copied when the watch fires, as any put's
  message is: into its slot when it has at most 8 bytes, otherwise into a
  chunk of the thread that fires it. No slot ever points at a watch's
  record, which goes back to its free list as soon as the watch has fired,
  or has been cancelled by its watcher's end; one compare-exchange of the
  record's state decides which of the two happens, and the thread that
  wins returns the record. An event's copy is never in a slot: it is its
  record's message, which the take copies from (§6.2).

No message `malloc`s. Segments and chunks are carved from regions that the
runtime reserves for queues, as it reserves data stacks, and go back to
free lists, never to the system: each free list is a stack whose top and
count change by one double-width compare-exchange, with a few entries
cached per thread in front of it, so taking or returning one needs no lock.
Memory a queue grows into for the first time still costs the system's page
faults (§3.4's 14.7 µs `burst` put is mostly those), but only the first
time: a queue in steady state reuses warm chunks, and a block taken on
another thread costs a decrement rather than a remote `free`. Chunks belong
to the runtime, not to the thread, so a message outlives its sender
(§11.2), and a chunk stays allocated while any message in it is queued,
which the queues' limits bound.

A thread may still hold a pointer into a segment after the segment has gone
back to a free list (§9.3), so queue memory is never unmapped while the
program runs. `trim_memory()` gives back its pages but not its addresses.
It first takes the free segments and chunks off the calling thread's cache
and the global free lists, so that no thread can be reusing one while it is
trimmed. It then discards the pages of their slots and of the chunks, as
it discards a data stack's unused ones (`MADV_DONTNEED` on Linux; on macOS
a fresh mapping laid over them with `MAP_FIXED`, which XNU swaps in
atomically; `MEM_RESET` on Windows), which keeps the addresses readable
and writable, and puts them back. It never discards segment headers, which
is why they live apart from the slots (§9.3): a segment's slots take 1 KB,
less than a page, so a header among them would be zeroed with its
neighbours', and a generation that a trim set back to zero would count up
again through values a stopped linker may hold. A thread that still holds
a pointer into trimmed slots reads zeros or old bytes: zero is no valid
state, and old bytes name a ticket that it is not looking for, so it
rejects them and starts again from the queue's header, as it does for a
segment recycled without a trim. The
next user of a trimmed segment or chunk initializes it, as it does any
recycled one.

### 9.5 Waiting: a parker per thread

Every thread has a **parker**: a 64-bit state word holding the thread's
count of waits, which grows by one at every wait and is never reset, and
whether the thread is `RUNNING`, `WAITING` or `CLAIMED`. The thread sleeps
on the word: on its low half with `futex` on Linux (a new wait or a claim
always changes the low half), on all of it with `WaitOnAddress` on Windows 8
and later and with `os_sync_wait_on_address` on macOS 14.4 and later. Goose
supports macOS from 13.3, and before 14.4 the thread sleeps on a
`dispatch_semaphore_t` beside the word, which its claimer signals once, and
`dispatch_semaphore_signal` never waits for anyone. A signal that comes
after the wait it was for has ended, at its deadline, is left in the
semaphore and wakes the thread's next wait once for nothing; like every
wake-up, that one rereads the word, and sleeps again while it says `WAITING`
(a futex wake-up that comes late is absorbed the same way). On any other
system the parker is phase 1's mutex and condition variable, and there a
waker can wait for the few instructions in which the thread it wakes holds
its own mutex.

Every queue counts the threads parked on it, and keeps a **waiter entry**
for each thread that has ever waited on it: the thread's record, fixed when
the entry is made, and the count of the wait the thread registered on this
queue, or zero. An inbox has one entry, its owner's; a global queue's
entries are an array that grows by blocks, never freed, and a thread appends
its entry, with one increment of the array's length, the first time it waits
on that queue, then keeps the entry's place. Only its thread writes an
entry, so registering is a store of the count, then an increment of the
queue's count of parked threads, and unregistering, when the thread wakes, a
store of zero, then a decrement. **Waking takes no lock**: a put that has to
wake a thread reads the entries with plain atomic loads and claims one with
a compare-exchange of that thread's parker (below), so no thread, stopped
anywhere, can delay a wake-up but the thread making it. On Linux, Windows
and macOS there is no lock at all in the waiting path of phase 2.

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
* **One message, one thread.** A put that finds parked threads claims one: a
  compare-exchange of the thread's state from (the count of the wait its
  entry registered, `WAITING`) to (that count, `CLAIMED`), so a thread can
  only be claimed for the wait it registered. A thread already claimed, or
  one whose count has moved on (it woke, at its deadline or for another
  queue's message, and may be waiting again on others), is passed over, and
  its entry left for its own thread to clear. A put starts its scan where
  the queue's last claim left off, so that claims go round the waiters, and
  stops at its first claim. The claimed thread then takes as any take does:
  in its rotation (§5.3), and within a type from its inbox before the global
  queue, whichever queue's put claimed it. A wake-up carries no message,
  only the news that one came, so it never changes which message a take
  prefers: a thread claimed for a global message that an awake thread takes
  first, while an addressed message and then another global one arrive,
  takes the addressed one. If another of its sources still holds a message
  and has threads parked on it, it wakes one of them in turn, so a message
  that wakes a thread is never left behind with its takers asleep. If it
  finds nothing, the message was taken by a thread that was awake, which is
  just as good. There is no thundering herd, and no wake-up is spent on a
  thread that has stopped waiting for it.

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
freed, with its id changed, so a pointer to one is always safe to read and a
reader checks the id it finds. The id-to-record map is written under
`gs_threads_mutex` when a thread starts or ends. Phase 1 reads it under that
mutex, and checks the inbox's owner under the inbox's own mutex, in the same
critical section as the link, so a record reused meanwhile is seen for what
it is. Phase 2 gives each thread a small cache of the records it addressed
last, so an exchange's puts to the same 16 workers never take the mutex; the
cache needs no check of its own, since a claim can only succeed with the
incarnation of the owner it addressed (§9.3). The recycled records keep
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
GS_API void gs_qlimit_inbox(gs_queue *q, int64_t n, const char *file, int line);
GS_API int64_t gs_thread_self(void);                   /* thread_id() */
GS_API gs_res gs_event_new(gs_queue *q, const void *data, int64_t size,
                           const char *file, int line);   /* a resource<event> */
GS_API void gs_event_close(gs_res e, const char *file, int line);
GS_API void gs_thread_watch(int64_t id, gs_queue *q, const void *data, int64_t size,
                            const char *file, int line);
int gs_event_signal(gs_res e);                          /* external linkage, also in goose.h */
```

`gs_qlimit` keeps its meaning, the global queue's limit, and
`gs_qlimit_inbox` sets the limit of the type's inboxes. A `resource<event>`
is the `gs_res` that step 0 gives every `resource<U>`, one `uint64_t`, here
and at an `extern fn`'s boundary. A take's view points into the message's
slot or chunk or, for an event's copy, into the event's record, and `hold`
says which, so that `gs_qdone` gives back what the take used: it finishes
the slot, and returns a closed event's record once its copy has been
handed over (§6.2).

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
destination, as a missed `qpoll` does. `event(v)` and `thread_watch(id, v)`
pack `v` as `qput` does and pass it with its queue; the runtime keeps the
copy. `qlimit_inbox<T>(n)` is `gs_qlimit_inbox(&q, n, file, line)`, as
`qlimit` is `gs_qlimit`. `thread_id()` is `gs_thread_self()`. The queues'
`gs_qinit` calls in `gs_program_init` also number the queue types, in the
sorted order the compiler already emits them, which is how a thread record
finds its inbox for a type.

## 11. The compiler's pieces

* **Builtins** (`builtins.h`): `B_THREAD_ID` (`thread_id`, 0 arguments,
  returns `i`), `B_QPUT_TO` (`qput_to`, 2), `B_SELECT` (`select`, 0 to 1,
  `BF_TYARGS`), `B_QLIMIT_INBOX` (`qlimit_inbox`, 1, `BF_TYARGS`, checked
  as `B_QLIMIT` is), `B_EVENT` (`event`, 1), `B_EVENT_CLOSE`
  (`event_close`, 1), `B_THREAD_WATCH` (`thread_watch`, 2). `B_QLIMIT` is
  unchanged. User functions of these names keep their calls, as for every
  builtin (`CheckNamedCall`): the one user `select` in the tests,
  `root_owner_choices.goose`'s, still resolves.
* **Checker** (`typecheck_builtins.h`, `CheckBuiltin`). `qput_to`: the id
  is an `i64`, the value is checked as `qput`'s (flat, not an untyped empty
  array, no index types). `event` and `thread_watch`: the same for `v`, and
  an `i64` id for the latter; `event` returns a `resource<event>`, the kind
  `event` being one that the runtime provides to the foundation's
  `resource<U>`, and `event_close` takes one. `select`: exactly one type
  argument; it must
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
  thread records with inbox tables, main's record, the parker, waiters and
  claims, inbox close at a worker's end, watches, inbox limits, the event
  table (its index and serial split, checked), the hint words kept with each
  thread record, and `gs_event_signal`; phase 2's slots claimed by
  double-width compare-exchange (one helper, `gs_cas128`, over `cmpxchg16b`,
  `casp` or `ldxp`/`stxp` and MSVC's `_InterlockedCompareExchange128`),
  incarnations, segments, chunks, lock-free free lists, queue regions and
  their trim, the fast parker, and the test hooks of §13 (`GS_QTEST_HOOK`,
  `GS_QTEST_PARKER_SEM`, nothing in a normal build). `goose.h` declares
  `gs_event_signal`, with `gs_res` if step 0 has not put it there. New
  aborts: `GS_E_NOTHREAD` ("qput_to or thread_watch of a thread id never
  issued"), `GS_E_WATCH` ("thread_watch of main or of the current thread"),
  `GS_E_EVENT` ("event_close of a handle that names no open event of this
  thread"), `GS_E_EVENTS` ("too many open events"); `qlimit_inbox` of zero
  or less is `GS_E_QBOUND`, as for `qlimit`. The runtime's text changes, so
  `GS_RUNTIME_VERSION` changes and runtime objects are rebuilt;
  `runtime_inline.h` is regenerated with `goose --gen-runtime-header`.
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
* **Events as a source of their own**, with `select` taking event handles
  beside types. That makes `select`'s sources partly runtime values, bound
  to variants by position, or by comparing handles, which `resource<U>`
  forbids, and gives a thread a second way to be woken. Delivering an event
  as a message keeps one way.
* **Events as queued copies**, a slot in the owner's inbox put by the
  signal that sets `pending`, which an earlier draft of this note had. A
  signal that merges into a copy whose putter has stopped before its put
  then reports a success that the owner cannot see, for as long as that
  thread is stopped; to prevent it, the merging signal must wait for the
  put, or put the copy itself, and then the signals have to agree on a
  single slot or the take has to recognize duplicates, whose slots count
  against the inbox's limit while they wait. A hint that every signal sets
  has no such window, needs no agreement and makes no duplicate (§6.2), and
  an event, a "look" from C, never needed a place in the queue's order.
* **Events as `i64` ids**, as thread ids are. A program could make one up
  and hand it to C, which is the argument against integer channel handles
  (§4.1); `resource<event>` makes a handle something only the runtime
  hands out, and keeps the C side a `uint64_t` all the same.
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
  claiming a shared slot costs about 35 ns here, which does not pay for
  the weaker order.
* **Tickets first, values after** (Vyukov's bounded queue, crossbeam's
  `ArrayQueue`, CRQ). §9.2: a taker that meets a ticket whose value is not
  there yet must wait for the putter, which lets a descheduled thread stall
  polls and deadlines, or kill the ticket, which breaks exact limits.

## 13. Testing

Following `docs/testing.md`: positive fixtures with expected output, abort
fixtures with `.aborts` and `.stderr`, and rejections with `// error:`
markers. Threads run only natively, so the new fixtures, like
`threads/`'s today, run at `-O0` and `-O2` and are skipped by the JIT.

* `threads/inbox_basic.goose`: `thread_id()` on main (-1) and in workers;
  `qput_to` a worker and back to main; inbox before global for one type;
  a sender's order, and two senders' order when one's put returned before
  the other's started (a message chain); a thread's own inbox.
* `threads/inbox_limits.goose`: `qlimit_inbox` limiting each inbox on its
  own and leaving the global queue unlimited, and `qlimit` limiting the
  global queue and leaving every inbox unlimited, as today's programs
  expect; a full inbox refusing at once and accepting again after a take;
  one full inbox not refusing another; a lowered limit; a limit of zero or
  less aborting (`runtime/qlimit_inbox_zero.goose`).
* `threads/inbox_ended.goose`: puts to a worker that returned and to a
  contained worker that aborted are `false`; messages left in its inbox are
  gone after `thread_wait`; `qput_to` to a worker before it first takes;
  a child's inbox outliving its parent.
* `threads/thread_watch.goose`: a watch on a running worker, on one that
  has ended (at once), several watches on one worker, a watch made by a
  worker that ends first (dropped); the report-before-end guarantee of
  §4.6; `thread_wait` returning at once after the watch message; watches
  whose messages have at most 8 bytes and larger ones, made and fired ten
  thousand times, each message arriving once with its own value and every
  watch record returned (the lifecycle test's live-record count).
* `threads/select_basic.goose`: one thread, messages of three types put
  in an order; the rotation order `select` takes them in; the timed form's
  zero value and `false`; `select<E>(0)` and a negative `ms` not waiting;
  a generic `E`; a variable-mode `E..` with a string field.
* `threads/select_wait.goose`: workers sleeping in `select` woken by each of
  their types, from the inbox and from the global queue; many workers
  selecting on one global queue and their inboxes, every message taken
  exactly once and none left with its takers asleep (claims and passing on);
  a thread woken for one queue taking another's message first; a deadline
  that passes with nothing, within its time; deadlines that end while a put
  claims the waiter, each returning at its deadline, and the late wake-up
  absorbed by the next wait. On macOS it runs a second time with the
  dispatch-semaphore parker forced (`GS_QTEST_PARKER_SEM`, nothing in a
  normal build), so that the path of macOS before 14.4 is tested on any
  macOS.
* `threads/event_signal.goose` with `event_signal.build` and
  `event_signal_impl.c`, a fixture with a sidecar, which the runner builds
  with `goose build`: C threads (pthreads, or `CreateThread` on Windows)
  signalling events of a worker and of main, before and during their waits;
  a burst of signals merging into one message; the handle of a closed event
  and of an ended thread's returning 0, and the zero handle and a word never
  handed out returning -1; an event's copy taken from an inbox that is
  full, against whose limit it does not count; a constantly signalled event
  and a stream of queued messages of its type, taken by turns; events
  whose messages have at most 8 bytes, many of one thread's at once,
  signalled and taken many times, each copy with its own event's value; a
  `resource<event>` sent in a message and handed to C by another thread.
* `threads/exchange_credits.goose`: §8.2 at small scale, 4 workers and
  windows of 2, every row arriving once at its owner.
* `threads/reports_watched.goose`: §8.1's collection with one contained
  worker aborting, finishing without a hang and with the abort's message.
* `threads/select_flood_timer.goose`: §7.2's loop, without coroutines: a
  worker keeps the loop's inbox full while the loop has a timer due every
  10 ms; over a second the timer fires about 100 times (at least 80), and
  every flooded message is taken.
* `runtime/` abort fixtures: `qput_to_unknown.goose` (an id never issued),
  `thread_watch_self.goose`, `thread_watch_main.goose`,
  `event_close_foreign.goose`, `event_close_twice.goose` and
  `event_close_zero.goose` (the zero handle).
* `errors_tc/`: `select` with no type argument, with a struct, with a
  variant of no field and one of two fields, with two variants of one type,
  with a non-flat field, an index-typed field and a resizable field, with a
  non-integer `ms`; `qput_to` of a non-flat value, with a non-integer id;
  `event` and `thread_watch` of non-flat values; `event_close` of an `i64`;
  `==` of two `resource<event>`s, which the foundation forbids; and
  `qlimit_inbox` without its type argument.
* `threads/runtime_threads_lifecycle.c`: records recycled under worker
  churn with no growth in live allocations; inboxes discarded at a
  worker's end with their messages' memory; events closed with their
  owners, signalled from a foreign thread racing the owner's end; phase 2's
  segments and chunks recycled, with no allocation in steady state.
* `threads/runtime_queue_stalls.c`, the direct test of the moments where
  a thread can stop and nobody may wait for it, run by the runner's
  runtime task as the lifecycle test is. It includes the runtime's source
  and defines `GS_QTEST_HOOK(point, queue)`, which the runtime calls at
  those moments and which is empty in every other build, to park a chosen
  thread at a chosen point until the test lets it go. Phase 1 brings the
  file and the hooks inside a signal (after its compare-exchange, after its
  hint) and between a thread's wake-up and its take, for the event and
  wake-up cases below; phase 2 adds the queue's own points:
  * **interrupted puts**: a put parked during its chunk copy, before its
    claim, after its claim and before it moves `tail`, and while it links
    a segment. Meanwhile a `qpoll` of that queue answers at once (a miss,
    or a message filled before), a `select(0)` over it and a second queue
    holding a message returns that message, a `qget(ms)` and a
    `select(ms)` return by their deadlines, and other puts to the queue
    succeed, or, on a limited queue, are refused exactly when it holds its
    limit; let go, the parked put's message is taken once, in its slot's
    order;
  * **a lagging `tail`**: a put parked after claiming the last slot of a
    segment and before moving `tail`, while consumers take that segment's
    messages and the next one's and another thread calls `trim_memory()`:
    the segment is neither recycled nor trimmed while `tail` is in it, the
    next put moves `tail` past it and recycles it, and the parked put, let
    go, finds `tail` moved and does nothing more; then the same with no
    other put, so that `tail` stays behind `head` until the parked put
    moves it; and the same with the inbox sealed while it is parked, every
    segment returned once;
  * **interrupted wakers and waiters**: a waker parked in the middle of
    its scan of a queue's waiter entries, and a waiter parked between
    storing its entry and counting itself parked, while puts to the queue
    wake its other parked threads and return at once; let go, the parked
    waker claims a thread that is still waiting, or none, and the parked
    waiter finds the message or parks, never missing one;
  * **owner reuse**: a sender parked after reading worker X's owner and
    incarnation and before its claim, while X ends and workers start and
    end until X's record has been reused 70,000 times (more than any 16-bit
    generation could count) and is held by a running worker Y; let go, the
    sender is refused, and Y's inbox receives nothing;
  * **stale segments**: a reader parked after loading a segment pointer
    while the segment is finished, recycled into another queue at the same
    tickets, and trimmed; let go, it rejects what it reads and goes on
    correctly;
  * **a link reused in its own queue**: a linker parked after reading its
    parent segment's `next` and generation, while the queue fills, drains
    and recycles that parent back into its own chain at a later ticket (the
    segment of tickets 0 to 63 reused for 128 to 191), with the same
    incarnation and `next` empty again; let go, its link fails on the
    generation, it rereads the chain, and every ticket is taken once and
    in order. Then the same with `trim_memory()` run while the parent is
    free, between its recycling and its reuse: the trim leaves the header,
    and so the generation, as they were, and the link fails as before;
  * **stale waiter entries**: a waker parked after reading a queue's waiter
    entry, while that waiter times out, returns, and parks again on other
    queues; let go, its claim fails on the count of waits, and it claims
    another thread parked on its queue, if there is one, leaving the entry
    for its own thread to clear; and a woken thread that takes another
    source's message first passes the wake-up on, so no message is left with
    its takers asleep;
  * **a wake-up keeps inbox first**: a thread parked in `qget<T>()`,
    claimed by a global put of `T` and parked by the hook before its take,
    while an awake thread takes that message and then an addressed message
    of `T` and another global one arrive; let go, it takes the addressed
    message, and the global one is left for the next take (phase 1 and
    phase 2);
  * **trim against reuse**: producers and consumers streaming through
    queues with 4-slot segments and small chunks (`GS_QSEG_SLOTS=4`), so
    that both recycle every few messages, while another thread calls
    `trim_memory()` in a loop: every message arrives once, nothing faults,
    under ASan as well, and live memory stays bounded;
  * **events closed under their copies**: an event signalled, closed and
    followed by a new event before the first copy is taken: the new event
    gets another record, the owner takes the first event's message and
    then the second's, and the first record is reused only after its copy
    has been taken;
  * **a paused publisher**: a C signal parked after its compare-exchange
    and before its hint, while the owner sleeps in `select`: a second
    signal merges, sets the hint, wakes the owner and returns 1, and the
    owner takes the copy while the first signal is still parked; let go,
    the first returns 1 and its hint is passed over, nothing being pending,
    and once more with a third signal before it is let go, whose copy is
    taken once. Then the first parked after its hint and before its
    wake-up: the second signal's wake-up is the one that wakes the owner;
  * **a signal parked across a close**: a C signal parked after its
    compare-exchange and before its hint, while the owner closes the event
    and makes others, and a signal of the closed handle returns 0: the owner
    takes the copy, with the closed event's own message, before the parked
    signal is let go, since the close set its hint; let go, the signal
    returns 1, and the record is reused only after the copy was taken;
  * **a signal parked across its owner's end**: the same signal parked
    while the owner ends and its thread record is reused 70,000 times, by
    workers with events of the same type in the same hint bits; let go, it
    returns 1, its copy having been discarded with the inbox, and its hint
    makes the record's current owner look and take nothing that was not
    signalled to it;
  * **stale event handles**: an event record reused many times: C
    signalling an old handle gets 0 and nothing arrives; with
    `GS_QTEST_EVENT_SERIAL_BITS=3` a record retires after its 7th event and
    the 8th gets another record, so no word ever names two events; with
    `GS_QTEST_EVENT_INDEX_BITS=4` the 17th open event aborts with "too many
    open events", which checks the index's side of the split.
* The sanitize profile runs all of these, and phase 2 runs the lifecycle
  test and the `select`/exchange fixtures under ThreadSanitizer once by hand,
  since the suite has no TSan profile.
* `bench/queues.py --quick` builds and runs every mode in seconds; phase 2
  runs the full session for §9.8.

## 14. Documentation

* **Spec §11.2**: inboxes and `thread_id`, `qput_to`, the takes' inbox
  first, `qlimit_inbox` beside an unchanged `qlimit`, order (§4.5, stated
  for the first time), a worker's end and what it does to inboxes, events
  and watches, `thread_watch`, `select` and its rules, events as
  `resource<event>` and `gs_event_signal`. §12's builtin table gains the
  seven builtins. The foundation step documents `resource<U>` itself, and
  §11.2 names `event` among the kinds the runtime provides. Appendix B TODO
  9 ("queue fairness/capacity, select") moves to Resolved, keeping its other
  items (worker-local init, sending self-contained relative-reference
  values).
* **Spec §7.10**: one paragraph naming `gs_event_signal` as the call C
  makes into the runtime, that it may come from any thread, and what its
  three answers mean; that a `resource<U>` crosses as a `uint64_t` is the
  foundation step's paragraph.
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

Phase 1 builds on the **foundation step** that both tracks share:
[step 0](shared_memory.md#step-0-resourceu-both-tracks) of
`shared_memory.md` §16, option C's `resource<U>` as that note's §4.1
specifies it. A handle is one `u64` (`gs_res` in C) that packs a
never-reused serial with a table index, flat and copyable, with no `==`, no
arithmetic and no conversion from an integer; it crosses an `extern fn` as
a `uint64_t`, and C may take a handle of the runtime's kinds but not return
one. Whichever of #3 and #5 comes to it first lands step 0, as that note
says. Phase 1 adds the kind `event` to it and uses it unchanged; steps 1
to 6 do not depend on it, and step 7 does.

### Phase 1 (#5): addressed delivery and `select`

1. **Thread records.** Recycled `gs_thread` records with a table of
   inboxes (a `gs_qstate` per queue type, made on first use), main's
   record, a thread-local pointer to the caller's own; queue type numbers
   from `gs_qinit`; the id-to-record map. No behavior changes.
2. **The take interface.** `gs_qmsg` and `gs_qdone`, `gs_qget`/`gs_qwait`
   taking from the inbox first; codegen of `qget`/`qpoll`/`qget(ms)`
   switched to them. No behavior changes: inboxes stay empty.
3. **Waiting.** The per-thread parker (mutex, condition variable, and the
   state word with its count of waits), waiter lists in each `gs_qstate`
   under its mutex, claims by the count of the registered wait, a woken
   thread taking as any take does (inbox first) and passing on what it
   does not take, absorbed spurious wake-ups, and the hook between a
   wake-up and its take for `runtime_queue_stalls.c`'s inbox-first case;
   the condition variable per queue goes. `bench/queues.py` within 10% of
   §3.2.
4. **`thread_id`, `qput_to` and `qlimit_inbox`**, with ended-worker
   refusal and never-issued aborts, inboxes closed and discarded at a
   worker's end before it is marked ended, and `qlimit` left as it is.
   Tests: `inbox_basic`, `inbox_limits`, `inbox_ended`, `qput_to_unknown`,
   `qlimit_inbox_zero`, the `qput_to` and `qlimit_inbox` rejections.
5. **`thread_watch`.** Tests: `thread_watch`, `reports_watched`, the watch
   aborts.
6. **`select<E>`**, fixed and variable mode: checker rules, the site
   rotation, `gs_qselect`. Tests: `select_basic`, `select_wait`,
   `exchange_credits`, the `select` rejections.
7. **Events**, on the foundation's `resource<U>`: the kind `event`, the
   event table with its index and serial split, `pending`, the hint words
   and their bits per inbox, signals that set the hint and wake the owner
   whether they made the copy pending or merged, takes by turns with the
   inbox's queued messages, and the return of a record to its free list
   only when it is closed with no copy pending (§6.2); `event`,
   `event_close` (which sets a pending copy's hint), and `gs_event_signal`
   with its three answers, external linkage, and a place in `goose.h`.
   Tests: `event_signal` with its C, the event aborts and rejections, the
   lifecycle test's foreign signals, and `runtime_queue_stalls.c` with its
   event cases: events closed under their copies, a paused publisher, and
   signals parked across a close and across the owner's end (§13).
8. **Documentation** (§14), and `bench/queues.md` re-measured.

### Phase 2 (#6): queue performance

1. **The parker.** `futex`, `WaitOnAddress` and `os_sync_wait_on_address` on
   the 64-bit state word with its count of waits, a dispatch semaphore on
   macOS before 14.4, and phase 1's as the fallback elsewhere; spin, then
   park, with `GS_QSPIN_NS` measured; a put's parked-count check after a
   fence; waiter entries that only their threads write, and that wakers
   claim from without a lock, passing stale ones over. Measure `rt2` and
   `tput` 1 × 16.
2. **Slots claimed and filled at once** (§9.3): `gs_cas128`, segments with
   their generations, in headers kept apart from their slots, recycled once
   their slots are finished and `tail` has passed them, incarnations,
   messages of up to 8 bytes in their slots, exact limits, inboxes sealed
   and reused, the test hooks and `runtime_queue_stalls.c`'s interrupted
   puts, a lagging `tail`, owner reuse, stale segments, links reused in
   their own queue and stale waiter entries; `gs_qstate` replaced. Measure
   `drain` and `tput` 16 B.
3. **Chunks** for messages over 8 bytes, the queue regions, lock-free free
   lists for segments and chunks, watch messages copied when they fire, and
   `trim_memory()`'s discarding of free queue memory without unmapping it,
   with the trim-against-reuse test. Measure 32 KB; no `malloc` per message
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
* **Should inbox limits be set per destination** (`qlimit_inbox<T>(id,
  n)`), or by each thread for its own inbox? No: one limit per type, set
  before the workers start, holds from every inbox's first message, which a
  limit a thread sets for itself after its spawn cannot; two bounds for one
  payload are two types (§4.4). Revisit if a program needs one receiver
  bounded tighter than its siblings for a type they share.
* **Should two `resource<event>`s be comparable?** No: the foundation's
  `resource<U>` has no `==`, and nothing here needs to know whether two
  handles name the same event, since an event's message tells its sources
  apart (§6.1). If a program ever must, a named builtin, not `==`.
* **Should `select` be able to wait for room in another thread's inbox?**
  No: credits give the same wake-up with a message, and a sender that
  waits for room in a receiver that waits for room in it would deadlock
  (§4.4).
* **File-descriptor events (`event_fd(fd, v)`)?** Not in phase 1 (§6.4).
  Add them when a library's completions cannot be bridged by a thread of
  its own at acceptable cost: io_uring at very high completion rates is
  the likely first.
* **`gs_event_signal` from a signal handler?** Not promised. Phase 1 wakes a
  parked owner through a mutex and a condition variable, which a handler may
  not touch. In phase 2 a signal is a compare-exchange, an `or`, a fence and
  loads (§6.2), plus, for a parked owner, a compare-exchange of its parker
  and a system call (§9.5); it takes no lock, so it never waits for anyone,
  not even the thread it interrupted, and it allocates nothing and puts
  nothing in a queue. That holds where the parker is a futex,
  `WaitOnAddress` or `os_sync_wait_on_address`; macOS's dispatch semaphores,
  before 14.4, are not documented as safe in a handler. Phase 2 could
  therefore make the promise, with a test that signals from a handler
  interrupting the owner in each of those steps, if a user needs it.
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
  the system?** Their pages, yes, in phase 2: the calling thread's and
  those on the free lists, so that a thread that queued a burst of large
  messages can release it. Their addresses, never: a thread may still hold
  a pointer into a free segment, so queue memory stays mapped, and a stale
  reader finds zeros or old bytes that its checks reject (§9.4).
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
[shared_memory.md](shared_memory.md) (§4.1, `resource<U>`; step 0 of §16),
[dynamic_externs.md](dynamic_externs.md);
[bench/queues.md](../../bench/queues.md).

* P. Tsigas and Y. Zhang, [A Simple, Fast and Scalable Non-Blocking Concurrent FIFO Queue for Shared Memory Multiprocessor Systems](https://www.cse.chalmers.se/~tsigas/papers/latest-spaa01.pdf), SPAA 2001: a value claimed into its array slot with one compare-exchange.
* C.-H. Shann, T.-L. Huang and C. Chen, [A Practical Nonblocking Queue Algorithm Using Compare-and-Swap](https://people.cs.nycu.edu.tw/~tlhuang/Papers/ICPADS00.pdf), ICPADS 2000: the same with a counter beside each slot's value, against ABA.
* D. Vyukov, [Bounded MPMC queue](https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue): a slot per ticket with a sequence number.
* crossbeam, [`SegQueue`](https://docs.rs/crossbeam-queue/latest/crossbeam_queue/struct.SegQueue.html): an unbounded lock-free MPMC queue of linked blocks of slots; [`ArrayQueue`](https://docs.rs/crossbeam-queue/latest/crossbeam_queue/struct.ArrayQueue.html): Vyukov's queue, whose takers wait for a put between its ticket and its value.
* M. Michael and M. Scott, [Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms](https://www.cs.rochester.edu/~scott/papers/1996_PODC_queues.pdf), PODC 1996: the two-lock queue.
* A. Morrison and Y. Afek, [Fast Concurrent Queues for x86 Processors](https://www.cs.tau.ac.il/~mad/publications/ppopp2013-x86queues.pdf), PPoPP 2013 (LCRQ): rings claimed with fetch-and-add, closed by a bit in the tail.
* Go, [`select` statements](https://go.dev/ref/spec#Select_statements) and the runtime's [`schedule`](https://github.com/golang/go/blob/master/src/runtime/proc.go) (the global run queue every 61st tick).
* tokio, [`select!`](https://docs.rs/tokio/latest/tokio/macro.select.html): random by default, `biased;` in order.
* Erlang, [processes and message passing](https://www.erlang.org/doc/system/ref_man_processes.html): mailboxes per process, ordering per pair of processes.
* libuv, [`uv_async_t`](https://docs.libuv.org/en/v1.x/async.html): a wake-up from any thread, merged while pending.
* Linux, [`eventfd(2)`](https://man7.org/linux/man-pages/man2/eventfd.2.html) and [`futex(2)`](https://man7.org/linux/man-pages/man2/futex.2.html); FreeBSD, [`kqueue(2)`](https://man.freebsd.org/cgi/man.cgi?kqueue) (`EVFILT_USER`).
