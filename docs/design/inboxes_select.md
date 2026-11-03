# Inboxes and `select`: messages to one thread, waits on several sources, and faster queues

<details>
<summary>Table of contents</summary>

- [1. Decisions](#1-decisions)
- [2. The boundary today](#2-the-boundary-today)
- [3. The builtins](#3-the-builtins)
- [4. Guarantees](#4-guarantees)
- [5. What happens at run time: phase 1](#5-what-happens-at-run-time-phase-1)
- [6. Faster queues: phase 2](#6-faster-queues-phase-2)
- [7. The generated C](#7-the-generated-c)
- [8. The compiler's pieces](#8-the-compilers-pieces)
- [9. Alternatives considered](#9-alternatives-considered)
- [10. Testing](#10-testing)
- [11. Documentation](#11-documentation)
- [12. The plan](#12-the-plan)
- [13. Deferred and open](#13-deferred-and-open)

</details>

Goose threads share no mutable memory and talk through typed queues, one per
flat type (§11.2). This note adds **addressed delivery**, to one thread by its
id; **`select`**, a wait for the next message of several types, including
events C signals when an I/O completes; and **faster queues**, with no `malloc`
and no lock shared by every put and take. All that §11.2 promises stays.
Written against `a646a68c`. Phase 1, delivery, `select` and events, is #5,
implemented (spec §11.2); phase 2, the queues' speed, is #6, its exact
lock-free protocol provisional (§6).

## 1. Decisions

* **No shared mutable memory.** New builtins copy flat values or name threads
  by id; none adds a shared object, an atomic, a lock or `unsafe`.
* **Inboxes, addressed by thread id.** Each thread has an inbox per queue type
  beside its global queue; `qput_to(id, v)` puts in one, takes look at the
  caller's first, and `thread_id()` names the caller, main being -1.
* **No channels.** The address is the id `thread_spawn` returns.
* **Ids.** `qput_to` to an ended worker is `false`, to a never-issued id an
  abort; a worker's inboxes are emptied before `thread_wait` for it returns.
* **Limits, purely additive.** `qlimit<T>` keeps its meaning; `qlimit_inbox<T>`
  limits each inbox. Nothing blocks; backpressure is credits.
* **Order.** Every queue, inbox or global, is first in, first out.
* **`thread_watch(id, v)`** puts `v` in the caller's inbox when `id` ends.
* **`select<E>()` and `select<E>(ms)`** take the next message of the types
  `E`'s one-field variants hold, rotating per call site so none starves.
* **Events from C are messages.** `event(v)` returns a `resource<event>`
  (`shared_memory.md` §4.1), and C's `gs_event_signal(e)` makes a copy of `v`
  pending in the owner's inbox; threads wake for messages and deadlines.
* **Coroutines.** `select<E>(ms)` is the primitive their libraries need.
* **Faster queues, no new surface.** Phase 2 changes only the runtime, its
  exact protocol provisional, #6's to prove against review's checklist (§6).
* **Measured first.** `bench/queues.md` is the baseline phase 2 must beat.

## 2. The boundary today

§11.2 gives each flat type one queue, a `gs_qstate` (`runtime_threads.h`):
nodes `gs_qput` `malloc`s, under a mutex and condition variable that `gs_qget`,
`gs_qwait` and `gs_qpoll` wait on. `B_QGET` copies a 32 KB message four times,
not two, and worker records (`gs_thread`) live under `gs_threads_mutex`.
Nothing sends to one thread, waits for two things or wakes a thread from C, and
`bench/queues.md` measures the rest: one lock serializes takers, a put to
sleeping takers makes a system call, and the allocator paces large messages.

## 3. The builtins

### 3.1 Addressed delivery

```goose
thread_fn worker() {                              // a work queue with addressed replies
    loop {
        let j = qget<Job>();                      // its inbox first, then the global queue
        if j.key < 0 { break; }                   // a stop, queued behind the jobs
        qput_to(j.from, Reply { key: j.key, value: lookup(j.key) });
    }
}
```

`thread_id() -> i64` is the caller's id, -1 on main; a job carries its
submitter's (`from: thread_id()`), so each submitter gets its own replies.
`qput_to(id, v) -> bool` puts flat `v` in thread `id`'s inbox for its type,
never blocking, and is `false` at once, queueing nothing, if that inbox is full
or `id` has ended; a statement drops it, as for `qput`. `qget<T>()`,
`qpoll<T>()` and `qget<T>(ms)` take the oldest message of the caller's inbox,
else of the global queue, waking for either, so programs that address nothing
are unchanged. A worker's inboxes exist before it starts. Ids stay `i64`s; an
event's handle, which lets C deliver a message, is a `resource<event>`.

### 3.2 Inbox limits and backpressure

`qlimit_inbox<T>(n)` limits every thread's inbox of `T` to `n` messages of its
own, and `qlimit<T>(n)` still limits only the global queue. Like `qlimit`, it
is program-wide, absent until called, an abort at zero or less, keeps what is
queued when lowered, and checks a racing put against the old limit or the new.
A watch's message is queued even into a full inbox, counting while it waits; an
event's pending copy counts against nothing. The limit is the type's, so main
can set it before any worker exists; two bounds for one payload are two types
(`struct Urgent { j: Job }`).

**Nothing blocks**, since a blocking put deadlocks two workers that wait for
room in each other's inbox. A sender retries a refused put later, or uses
**credits**: a receiver grants each sender `k` messages and returns a credit
per `k / 2` taken, and a sender without one waits in `select`, draining its
inbox, so only an ended receiver refuses, and an inbox holds `k` per sender:

```goose
fn send(x: Exchange&, d: i64, b: const Batch&) {  // to d, the owner of b's partition
    while x.credits[d] == 0 { receive(x); }       // select<Traffic>(): a Batch, or a Credit
    let ok = qput_to(x.peers[d], b);
    assert(ok);                                   // with a credit, only an ended receiver refuses
    x.credits[d]--;
}
```

### 3.3 `thread_watch`, and a worker's end

When a worker returns, or aborts while contained, the runtime (1) releases its
storage; (2) closes its inboxes and events, discarding messages and pending
copies, and cancels the watches it made; (3) marks it ended, for `thread_wait`;
(4) fires the watches on it. Then `qput_to` to it is `false` and all it put is
queued; a put or a signal made as it ends may succeed and be discarded unread,
as on any asynchronous queue. `thread_watch(id, v)` puts a copy of flat `v` in
the caller's inbox at step 4, at once if `id` has ended, exactly once if it is
ending, and even into a full inbox, dropping it if the watcher has ended. Any
thread may watch any worker, any number of times; watching main, oneself or a
never-issued id aborts. The message finds the replies queued and `thread_wait`
answering at once:

```goose
thread_watch(id, Ended { id: id });               // as each worker is spawned
match select<Collect>() {                         // enum Collect { Reply { r: Reply }, Ended { e: Ended } }
    Reply r => record(r.r),
    Ended e => { if !thread_wait(e.e.id) { print("worker ", e.e.id, " aborted"); } },
}
```

### 3.4 `select`

```goose
enum Work { Job { j: Job }, Control { c: Control }, Io { d: IoDone } }
match select<Work>() {                            // the next Job, Control or IoDone
    Job j => run(j.j),
    Control c => stop(c.c),
    Io d => reap_reads(),
}
let w, got = select<Work>(10);                    // at most 10 ms; else Work's zero value, false
```

`select<E>() -> E` blocks until it takes a message of a field type of `E`'s
variants and returns it in its variant; `select<E>(ms) -> E, bool` waits as
`qget<T>(ms)` does, `E`'s zero value and `false` on a miss, polling at zero or
less. Each variant holds one field, of any name, whose type it receives, inbox
first, so senders put plain types that any `select` may receive. The types are
distinct, flat, free of index types (§3.11) and not zero-size (§3.4), so a
message has a byte at least (`enum Control { Stop, Cancel }`). `E` may be
generic, and is `select<E..>()` for a variable-size field (§3.5); a resizable
field is refused for now ("select cannot receive a resizable value yet; take it
with qget"). A `select` takes only what it returns, waits on its queues and
deadline alone, and returns a waiting message whatever its timeout, so a loop
with timers checks them every turn.

**What a coroutine library needs.** `coroutines.md` makes event loops, timers
and channels libraries (its §4.13). No library can write the thread's own wait
when no coroutine can run: sleep until a message from another thread or from C,
or the next timer, and say which. That is `select<E>(ms)`, `ms` the time to the
next timer and events bringing a reactor's completions; it calls no Goose code
from C, and gives each thread-per-core loop an address, for replies and flat
frames (its §4.9).

### 3.5 Events from C

```goose
let done = event(IoDone { file: 3 });             // a resource<event> of this thread
read_async(fd, 0, 65536, done);                   // an extern fn, whose C signals done
qget<IoDone>();                                   // the I/O completion, as a message
event_close(done);
```

`event(v) -> resource<event>` makes an event of the calling thread holding a
copy of flat `v`, a handle that is option C's `resource<U>` as
[`shared_memory.md`](shared_memory.md) §4.1 specifies it: one `u64` to copy,
store, send and pass to an `extern fn`, never compared, computed with or made
from an integer, the zero handle naming nothing. A signal makes a copy of `v`
**pending** in the owner's inbox for `v`'s type, or merges into the one
pending, and returns once it can be taken and a waiting owner is woken: a burst
wakes the owner once, every signal at least once after it. Takes find a pending
copy before the global queue, by turns with queued messages, unordered with
them and counted against no limit. `event_close(e)` closes the caller's event:
later signals return 0, and a pending copy stays. Closing another thread's
event, a closed one or the zero handle aborts. An event carries only `v`, so
each source gets its own.

```c
/* goose.h. Makes e's message pending in its thread's inbox, unless it is,
   and wakes the thread. 1: a copy is pending and can be taken; 0: e's event
   is closed, by event_close or its thread's end; -1: e never named one. */
int gs_event_signal(gs_res e);
```

A `resource<event>` crosses an `extern fn` (§7.10) as `gs_res`, a `uint64_t`,
which C may take and keep but, like every runtime kind, never return. Any
thread may signal at any time, before, during or after the owner's waits, and
after a close or the owner's end (0), so a library stops without a handshake;
the runtime only reports 0 and -1, which only the library can judge.
`gs_event_signal` has external linkage in every runtime build, for packages'
native parts. Goose has no `event_signal`, as `qput_to` wakes threads, and C no
`qput_to`: Goose builds the value, C says only when.

## 4. Guarantees

**Order.** Every queue is first in, first out, as today's are and §11.2 is to
state: a put that returned before another started is taken first, from whatever
threads, so "data, then done" works across queues. Between queues, an inbox
comes first, `select`'s rotation orders types, a pending event copy is ordered
with nothing, and two kinds of message that need an order are sent as one enum.

**Fairness.** A `select` site's rotation, per thread, starts after the variant
it returned last, so a type with a message is taken within as many calls as `E`
has variants, deterministically; in an inbox, pending copies and queued
messages take turns. An inbox that never empties starves its type's global
queue for that thread, which is what addressing is for; priority is the
program's, a `qpoll` of the urgent type first.

**No lost wake-up, no spurious return.** A message put while threads wait is
taken, by one of them or one that was awake, never left with all its takers
asleep: a woken thread takes as any take does, waking a sleeper of any queue it
leaves a message on. A return is a message or the deadline, on the monotonic
clock; spurious wake-ups are absorbed, and a thread that lost its message waits
on with its time left. A signal returning 1 has its owner awake or waking.

**The cost of waiting.** With nothing ready, a `select` checks its sources and
sleeps, using no CPU, its deadline the timeout. A check is a lock per queue in
phase 1, about the 13 ns of today's empty `qpoll`, and in phase 2 two loads
from cached lines and a spin of about a wake-up's cost. One system call wakes a
sleeper, and in phase 2 a put with nobody parked makes none. A program that
uses none of the new builtins pays only the inbox check.

**Ended and never-issued ids.**

| id | `qput_to(id, v)` | `thread_watch(id, v)` | `thread_wait(id)`, today |
|---|---|---|---|
| -1, main | main's inbox | aborts | aborts |
| a running worker | its inbox | watches it | waits |
| a worker that returned, or aborted while contained | `false` | `v` arrives at once | returns at once |
| the caller's own | its own inbox | aborts | aborts |
| never issued: below -1, or not yet returned by `thread_spawn` | aborts | aborts | aborts |

`thread_wait`, not `qput_to`, tells a return from a contained abort; a
never-issued id aborts ("qput_to or thread_watch of a thread id never issued").
`false` always means not queued, so a sender that retries a refused put also
watches for its receiver's end.

## 5. What happens at run time: phase 1

Phase 1 is built from `gs_qstate` and mutexes; like today's queues, it can wait
for a mutex that a descheduled thread holds.

**Records and inboxes.** Every thread, main included, has a record: id,
inboxes, parker, event hint words, watches, and a mutex for rare changes.
Records are recycled with a new id, never freed, so pointers to them stay safe
and readers check the id; ids are issued in order, so one at or past the next
was never issued (`GS_E_NOTHREAD`), with nothing kept per ended worker. Inboxes
are found by type number (§7) in a table of pointers, each written once under
the record's mutex with a release store, read with an acquire load, and made by
the first take, event or put that needs one, a put only for the owner it
addresses. An inbox, a `gs_qstate` with its owner's id and a closed flag, is
never freed: its owner's end first closes the record to new inboxes, then
closes and empties each inbox, freeing nodes after letting go, and it reopens
for the next owner. `qput_to` finds the record under `gs_threads_mutex`, then
in one critical section of the inbox's mutex checks owner, openness and limit,
links and wakes: a put lands before the inbox closes or is refused. Takes hold
one queue's mutex at a time; the inbox limit is one atomic word per type.

**Waiting.** A parker is a mutex, a condition variable and a state word under
that mutex: a count of waits, which grows at every wait and survives a change
of owner, and `RUNNING`, `WAITING` or `CLAIMED`. Each queue lists its waiters
under its mutex, a record and a count each. A take that finds nothing becomes
(its count plus one, `WAITING`), joins its sources' lists, looks again, and
sleeps while still so. A put after linking, or a signal after its hint, claims
the first entry whose thread is (its count, `WAITING`), setting `CLAIMED` under
the parker's mutex, dropping stale entries, then signals it with both mutexes
let go, so no put waits for a wake-up's system call; mutexes nest only queue,
then parker. The woken thread becomes `RUNNING`, leaves the lists, takes as any
take does, and passes its claim to a waiter of the global queue that claimed it
if it took nothing there; a deadline that meets a claim acts on it. Claims
compare counts, so an ended worker's entry never claims its record's next owner.

**Watches.** A watch sits in its worker's list and its watcher's, each under
its record's mutex. `thread_watch` links it into both, unless the worker has
ended or its list fired, when it puts the message at once. An end takes its
whole list, a worker's marked fired and a watcher's closed, and settles each
watch by compare-exchange, armed to fired or cancelled; the winner unlinks it
from the other list, and puts a fired watch's message after letting every mutex
go. A count of two frees each watch with the last list to drop it.

**Events.** Event records are in a table of blocks that never move and are
never freed. A handle's bits 63 to 24 are its record's serial and bits 23 to 0
its index (`GS_RES_SERIAL_BITS`, `GS_RES_REGION_BITS`); a serial grows by one
at each new event and retires at 2^40 - 1, so no word names two events, and
serial 0, which no record has, names none. At most 2^24 records are in use,
from `event` until closed with nothing pending ("too many open events" beyond),
on a free list only the owner's side locks. A record holds a state word
(serial, open, pending), the message, and the place of its **hint**, a bit in a
never-freed hint word of the owner's inbox for the message's type that tells
takes to look. A signal reads the record at the word's index: the record's
serial with the event open is a signal (1); an older serial, every one of which
was handed out, or the same one closed, is stale (0); serial 0, a newer serial
or an index past the table was never handed out (-1). It sets `pending` by
compare-exchange, or merges, then sets the hint by atomic `or` and wakes the
owner before it returns 1, finishing the work of a signal stopped before its
hint, which at most wakes the owner once more. It runs no Goose code, allocates
nothing, and reads the record's other fields atomically. A take clears the hint
by atomic `and`, then `pending` by compare-exchange from (the serial it gave
that bit, pending), and copies the message; a hint with nothing pending is
passed over. Only the owner returns a record, closed with nothing pending: at
`event_close`, at the take of a closed event's copy (`gs_qdone`), or at its
end; a close that finds a copy pending sets its hint, so it is still taken.

## 6. Faster queues: phase 2

Phase 2 (#6) changes only the runtime, behind §7's interface. Its approach,
invariants and targets are settled; its protocol (§6.2) is **provisional**, and
#6 owns it. #6 may change any of it, as long as the invariants and the targets
hold, and merges only with an argument that each invariant holds, which review
can check, and a deterministic test of every row of §6.3, passing with §10's
stress runs under the sanitize profile and ThreadSanitizer.

### 6.1 Approach, invariants and targets

**The approach.** A queue is a sequence of ticketed slots in recycled segments,
each slot claimed and filled in one step, so no take waits for a put. A message
of up to 8 bytes travels in its slot, a larger one in the sender's current
256 KB chunk, recycled once its messages are taken, or, over 64 KB, in a chunk
of its own, rounded up to 64 KB; a watch's message is copied when it fires, an
event's copy is never in a slot, and no message `malloc`s. Each thread has a
parker, a 64-bit word in its record that it sleeps on with `futex`,
`WaitOnAddress` or `os_sync_wait_on_address` (a `dispatch_semaphore_t` on macOS
13.3 to 14.4, phase 1's parker elsewhere); it spins about a wake-up's cost
(`GS_QSPIN_NS`, measured per platform) before parking, and a put wakes it only
if it is parked. A value is copied once in, from `qput`'s lvalue, and once out,
into its destination; a batched API would save only what costs least.

**The invariants.** *The semantics, exactly*: copies, a `qput` that never
blocks, exact limits, first in first out, inbox first, `select`'s rotation. *No
lost wake-up* (§4). *No stall past a deadline*: `qpoll` and `select(0)` answer
at once, timed takes return by their deadlines, and no take, put or wake-up
waits for a thread stopped mid-operation. *Safe reuse*: no stale pointer, word
or handle acts on memory or a record since reused, and nothing a pointer may
reach is unmapped. *Bounded memory*: what is queued, as limits bound it, plus
free lists that `trim_memory()` can give back.

**The targets.** `bench/queues.py` decides: no cell of `bench/queues.md` more
than 10% slower, and these met. Phase 1 did, but for a 16 B `qget`'s 3 ns.

| figure | today | target | what makes it reachable |
|---|---:|---:|---|
| `rt1`, 32 KB | 4.1 µs | at most 2 µs | two copies in cache, not four |
| `empty`, a poll that finds nothing | 13 ns | at most 10 ns | four loads from lines nobody writes |
| `rt2`, 16 B, median | 13.6 µs | at most 2 µs | the answer arrives while the waiter spins (0.24 µs) |
| `drain`, 16 B, 1 consumer | 22.9 M/s | at least 20 M/s | no worse alone |
| `drain`, 16 B, 2 to 16 consumers | 3.4 to 4.4 M/s | at least 10 M/s each | a compare-exchange and a count per take, 45 ns |
| `tput`, 16 B, every pair of counts | 0.20 to 3.56 M/s | at least 5 M/s each | no wake-up while takers are awake |
| `tput`, 32 KB, 1 × 1 | 9.8 GB/s | at least 12 GB/s | one copy out from another core, 1.85 µs |
| `tput`, 32 KB, every pair of counts | 3.9 to 38.6 GB/s | at least 10 GB/s each | no allocator in the path |

### 6.2 The protocol, provisional

A queue holds `tail` and `head`, counters that never wrap, and a chain of
64-slot segments. A slot is a state word (`(t + 1) << 2 | kind`: ticket, and
empty, full or closed) and a value word, the queue's 64-bit **incarnation**
while empty, the message or its address once full. A put refuses at the limit,
claims slot `tail` by one double-width compare-exchange (`cmpxchg16b`; `casp`
or `ldxp`/`stxp`) from (empty, incarnation) to (full, message), moves `tail`
on, and after a fence wakes only a parked thread; a take claims slot `head` by
a compare-exchange of `head`. An inbox's incarnation, new for each owner, is
read with the owner's id as a sequence lock; an end seals the inbox, owner -2.
Free segments and chunks sit on lock-free lists, and `trim_memory()` discards
their pages in place (`MADV_DONTNEED`, `MAP_FIXED`, `MEM_RESET`). A parker's
word holds a count of waits and `RUNNING`, `WAITING`, `CLAIMED` or `WOKEN`.
Threads cache the records they last addressed, and every compare-exchanged word
carries a never-repeating number.

### 6.3 What #6 must prove

Review found these hazards. #6 may keep or replace each proposal, and lands a
deterministic test of each, played out by `runtime_queue_stalls.c` (§10) unless
another test is named:

| # | Hazard | Proposal | Test |
|---|---|---|---|
| 1 | A put stopped between its ticket and its message made takes wait, stalling `qpoll`, `select(0)` and deadlines | claim and fill in one double-width compare-exchange | interrupted puts |
| 2 | A sender stopped between checking an id and claiming fills a newer worker's inbox; a 16-bit generation repeats | an incarnation that never repeats, read with the owner as a sequence lock, compared by the claim | owner reuse, 70,000 reuses |
| 3 | A free segment may still be reached through a pointer read before it was recycled | never unmap; a trim discards pages in place | stale segments; trim against reuse |
| 4 | A linker stopped after reading `(next = NULL, incarnation)` links tickets 64 to 127 after its parent was recycled to 128 to 191 | a generation beside `next`, compared by the link | a link reused in its own queue |
| 5 | A linker pairs a free segment's new generation with its old header | generations odd in a chain, even while free; a link accepts only an odd one unchanged around its read of the header | a segment between return and reuse |
| 6 | A header among its slots is zeroed by a trim, and its generation counts up again through values a stopped linker holds | headers in a table of their own, never trimmed | a link reused in its own queue, with a trim between |
| 7 | Recycling a segment whose last slot a stopped put claimed removes the slot the next putters need to move `tail` on | recycle once all slots are finished (`gs_qdone`) and `tail` has passed too | a lagging `tail`, with reuse, trimming and a seal |
| 8 | An event's or a watch's small message, carried in its slot, names no record | an event's copy is never in a slot; a watch's message is copied when it fires | small events and small watches, many times over |
| 9 | A stopped holder of a waiter list's lock keeps parked takers asleep | no lock in waiting: threads write their own entries, wakers claim by compare-exchange | interrupted wakers and waiters |
| 10 | A claim whose system call is not yet made leaves its thread asleep while later puts and signals pass it over | whoever finds a thread claimed and not woken makes the call too | a claim held before its wake-up |
| 11 | An entry of a thread that woke for another queue, or of an ended worker whose record has a new owner, claims a wait it did not register | claims compare the registered count of waits | stale waiter entries; a deadline that meets a claim, with record reuse |
| 12 | A wait that returns at its deadline as it is claimed loses the claim | the deadline's compare-exchange; a thread that loses it acts on the claim | a deadline that meets a claim |
| 13 | Before macOS 14.4, a mutex and condition variable parker makes a waker wait for the thread it wakes | a dispatch semaphore | `select_wait` with the semaphore parker forced |

Phase 1's share is settled in §5 and tested by #5: event records and their
reuse, a signal's copy, inbox first after a wake-up, claims made with their
wake-ups, the watch lists, and an event loop's timers (§3.4).

## 7. The generated C

Phase 1 changes the runtime interface once, so that phase 2 changes only the
runtime: a take returns a view and a token, given back after the copy.

```c
typedef struct gs_qmsg { const uint8_t *data; int64_t size; void *hold; } gs_qmsg;
GS_API void gs_qget(gs_queue *q, gs_qmsg *m);                     /* blocks */
GS_API uint8_t gs_qwait(gs_queue *q, int64_t ms, gs_qmsg *m);     /* qget(ms); qpoll: ms 0 */
GS_API int64_t gs_qselect(gs_queue *const *qs, int64_t n, int64_t ms, uint32_t *at, gs_qmsg *m);
GS_API void gs_qdone(gs_qmsg *m);                                 /* after the copy */
```

`hold` names the node (phase 1), slot or chunk (phase 2) or event record that
`gs_qdone` frees, finishes or returns. `gs_qselect` takes a site's queues,
variant `i` receiving queue `i`, and the site's rotation in a `static GS_TLS
uint32_t`, and returns the tag it took, or -1 at its deadline; `ms` below zero
blocks, and `select`'s is clamped to zero as `qget`'s is. The message is copied
into the union, or onto the data stack, tag first, for an `E..`; a missed timed
`select` zeroes it. The rest call `gs_qput_to`, `gs_qlimit_inbox`,
`gs_thread_self`, `gs_thread_watch`, `gs_event_new` and `gs_event_close`, `v`
packed as for `qput`, and `gs_qinit` numbers the queue types, in the order the
compiler emits them.

## 8. The compiler's pieces

* **Builtins** (`builtins.h`): `B_THREAD_ID` (0 arguments), `B_QPUT_TO` (2),
  `B_SELECT` (0 to 1, `BF_TYARGS`), `B_QLIMIT_INBOX` (1, `BF_TYARGS`),
  `B_EVENT` (1), `B_EVENT_CLOSE` (1), `B_THREAD_WATCH` (2); user functions of
  these names keep their calls, as `root_owner_choices.goose`'s `select` does.
* **Checker** (`CheckBuiltin`): ids are `i64`s, values are checked as `qput`'s,
  `event` returns the `resource<event>` that `event_close` takes, and `select`
  takes an enum of one-field variants of distinct types `qget<T>` accepts, none
  resizable, and an optional `i64` that adds a `bool`. Errors name the variant:
  "select<Work>: variant Io must hold exactly one field, the message it
  receives", "select<Work>: variants Data and Retry both receive Batch".
* **Codegen** (`codegen_builtins.h`): `EmitBuiltin` cases, a rotation per
  `select` site, `B_QGET` on `gs_qmsg`, phase 2's copy elisions, and
  `usesthreads`, so the JIT refuses these programs.
* **Runtime** (`runtime_threads.h`): §5, §6, `gs_cas128` and §10's hooks. New
  aborts: `GS_E_NOTHREAD`, `GS_E_WATCH` ("thread_watch of main or of the
  current thread"), `GS_E_EVENT` ("event_close of a handle that names no open
  event of this thread"), `GS_E_EVENTS`; `qlimit_inbox` below one is
  `GS_E_QBOUND`. `goose.h` declares `gs_event_signal`; `GS_RUNTIME_VERSION`
  changes, and `runtime_inline.h` is regenerated.
* **No syntax**: parsers, formatter, grammars and language server unchanged.

## 9. Alternatives considered

| Alternative | Why not |
|---|---|
| Channel handles, a flat `chan<T>` one thread makes and passes on | who takes from one, and when it is freed, need answers that inboxes give by construction; several queues of one type per thread are wrapper types |
| Receives that pick a message by a tag or a pattern | a receive scans its queue, at a cost that grows with what is queued, and an unmatched message stays forever; types select at compile time |
| `select` as a statement with arms | new syntax for what a typed call and `match` say, and arms are no value a library can wrap or return |
| A readiness wait, `wait_any(sources, ms)`, then `qpoll` | another thread can take a message reported ready, so every caller loops; and types have no values to pass |
| Events as a source of their own in `select` | sources become runtime values, bound to variants by position or by comparing handles, which `resource<U>` forbids |
| Events as copies queued by the signal that sets `pending` | a signal merging into a copy whose putter stopped reports a copy the owner cannot see; mending it needs waiting, or duplicates |
| Events as `i64` ids; a per-thread signal word; C posting typed messages | a program could make an id up; libraries would share 64 bits; C would build Goose values and name queues, and nothing would merge |
| Blocking puts with a timeout | any blocking put can deadlock workers that send to each other, and credits wake a sender without one |
| A separate `qrecv<T>()` for inboxes | it doubles the takes and `select`'s sources, where `qget` reading both changes nothing for programs that address nothing |
| An ended worker's messages kept, or moved to the global queue | nobody else reads an inbox, ids are never reused, and a moved message reaches a thread its sender did not address |
| Phase 2: a node pool behind the lock; a lock each for putters and takers; rings or shards per sender | the lock stays, the largest cost in `bench/queues.md`; sixteen takers still collide; only each sender's order is kept, to save a compare-exchange of about 35 ns |
| Phase 2: a ticket per put (`fetch_add`), its slot filled after | a take that meets the ticket first must wait for the put, so a descheduled putter stalls deadlines, or kill the ticket, which breaks exact limits |

## 10. Testing

Fixtures follow `docs/testing.md`, natively at `-O0` and `-O2` (no JIT).

* **`threads/`**: `inbox_basic`; `inbox_limits` (limits switched between 4 and
  64 under eight putters, never exceeded nor refusing early); `inbox_ended`
  (puts racing a thousand ends and reuses, none reaching a later owner);
  `thread_watch` (ten thousand fires, each once, and ten thousand short-lived
  watchers, live records bounded by the lifecycle test); `select_basic`;
  `select_wait` (no message lost or stranded, deadlines met by claims; #6's
  semaphore parker forced by `GS_QTEST_PARKER_SEM`); `select_flood_timer` (a 10 ms
  timer firing at least 80 times a second under a flooded inbox);
  `event_signal` (`event_signal.build`, `event_signal_impl.c`, C threads
  signalling); `reports_watched` (§3.3, with a contained abort);
  `exchange_credits` (§3.2, 4 workers, windows of 2).
* **Aborts and rejections**: `runtime/qput_to_unknown`, `qlimit_inbox_zero`,
  `thread_watch_self`, `thread_watch_main`, `event_close_foreign`,
  `event_close_twice`, `event_close_zero`; `errors_tc/`, each rule of §8, `==`
  of two `resource<event>`s, `qlimit_inbox` without its type.
* **The runtime directly**: `threads/runtime_threads_lifecycle.c`, live
  allocations flat under churn, and `runtime_queue_stalls.c`, whose
  `GS_QTEST_HOOK(point, queue)`, empty elsewhere, parks a thread at a chosen
  point: #5's cases are events closed under their copies, publishers paused
  before their hint, signals paused across a close and across 70,000 reuses of
  their owner's record, stale handles (`GS_QTEST_EVENT_SERIAL_BITS=5`,
  `GS_QTEST_EVENT_INDEX_BITS=4`), inbox first after a wake-up, a claim and its
  wake-up, and deadlines meeting claims; #6's, the rows of §6.3, with
  `GS_QSEG_SLOTS=4`. All run under the sanitize profile, and phase 2's also
  under ThreadSanitizer, by hand.

## 11. Documentation

Spec §11.2 gains this note's §3 and §4, order stated for the first time, and
`event` among the runtime's kinds; §12's table gains the seven builtins, §7.10
`gs_event_signal`, and Appendix B moves TODO 9 to Resolved, keeping its other
items. Reference §22 gains the builtins and "Messages to one thread", "Waiting
for several things" and "Events from C". `docs/implementation.md` §6.8 gains
the `gs_qmsg` interface, and its §7 the runtime of §5 and §6 above;
`docs/packages.md` ("The native part"), `docs/testing.md` and `bench/queues.md`
gain `gs_event_signal`, the fixtures and phase 2's session.

## 12. The plan

Each step is one working commit with the suite green. Phase 1 adds the kind
`event` to the foundation both tracks share, option C's `resource<U>` (#9, step
0 of `shared_memory.md`'s plan), which only its step 7 needs.

**Phase 1 (#5).** 1. Thread records (§5) and type numbers, with no behavior
change. 2. The take interface (§7), inboxes still empty. 3. Waiting (§5), with
`runtime_queue_stalls.c` and its claim, wake-up and deadline cases, and
`bench/queues.py` within 10%. 4. `thread_id`, `qput_to`, `qlimit_inbox`, ends
and refusals. 5. `thread_watch`. 6. `select<E>`, both modes. 7. Events, on the
foundation. 8. Documentation, and `bench/queues.md` measured again. Built, the
runtime first and then the builtins, as §5 and §10 now say (`bench/queues.md`).

**Phase 2 (#6)**, provisional as §6 says: #6 may change these steps, but not
§6's gate, invariants or targets. 1. Parkers, `GS_QSPIN_NS` measured, and
§6.3's rows 9 to 13; measure `rt2` and `tput` 1 × 16. 2. Slots, segments,
generations, incarnations, exact limits and sealed inboxes, with rows 1, 2, 3
(stale segments), 4, 5 and 7; `gs_qstate` goes; measure `drain` and `tput`
16 B. 3. Chunks, regions, free lists, watch messages copied when fired,
`trim_memory()`, with rows 3 (trim against reuse), 6 and 8; measure 32 KB, and
no `malloc` per message. 4. Copies. 5. The lookup cache. 6. The targets met,
recorded in `bench/queues.md`, and `docs/implementation.md` §7.

## 13. Deferred and open

| Question | This note's answer |
|---|---|
| `true` from `qput_to` to an ended worker? | No: `false` keeps one meaning, and retrying senders watch their receivers |
| Inbox limits per destination, or set by each thread? | No (§3.2), unless one receiver needs a tighter bound than its siblings for a type they share |
| `==` on `resource<event>`? | No: `resource<U>` has none, and an event's message tells its sources apart; if ever needed, a named builtin |
| A `select` that waits for room in another inbox? | No: credits give that wake-up as a message, and two such waiters could deadlock |
| Events for file descriptors (`event_fd(fd, v)`)? | Not in phase 1: platform-specific, a thread would sleep in `poll`, and a library can bridge a descriptor to `gs_event_signal` with a thread of its own; add them when that hop costs too much, without changing `select` |
| `gs_event_signal` in a signal handler? | Not promised, since phase 1 wakes through a mutex; phase 2 could promise it, with a test, where the parker is a futex, `WaitOnAddress` or `os_sync_wait_on_address`, but not with the dispatch semaphores before macOS 14.4 |
| The global queue now and then before a busy inbox? | No: inbox first is a rule a program can rely on |
| A `biased` `select`, in declaration order? | Not until a `qpoll` first proves too little |
| Batched `qput_n` and `qget_n`? | Not in phase 2 (§6.1); measure again after it |
| Deadlines in nanoseconds? | No: milliseconds, as for `qget(ms)`; revisit for a loop that needs finer timers |
| Resizable fields in `select`? | When a program needs them; `qget` takes them today |
| A fixed or an adaptive spin? | Fixed per platform, overridable at compile time; adaptive after phase 2, if workloads differ |
| Main as -1? | Yes: existing ids stay what they are |
| A non-blocking "has it ended" query? | No: `thread_watch` answers with a message, which composes with `select` |
