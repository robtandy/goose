# Immutable shared memory: mapped files and frozen regions

<details>
<summary>Table of contents</summary>

- [0. Decisions](#0-decisions)
- [1. What the feature is for](#1-what-the-feature-is-for)
  - [1.1 The invariant](#11-the-invariant)
  - [1.2 The uses](#12-the-uses)
  - [1.3 The constraints](#13-the-constraints)
- [2. The boundary today](#2-the-boundary-today)
  - [2.1 Why queues and spawn arguments copy](#21-why-queues-and-spawn-arguments-copy)
  - [2.2 Why an `extern fn` cannot return a slice](#22-why-an-extern-fn-cannot-return-a-slice)
  - [2.3 What a program does instead, and what it costs](#23-what-a-program-does-instead-and-what-it-costs)
  - [2.4 What Goose already has](#24-what-goose-already-has)
- [3. The model](#3-the-model)
- [4. Syntax and type rules](#4-syntax-and-type-rules)
  - [4.1 `resource<U>`, the first step](#41-resourceu-the-first-step)
  - [4.2 Arenas and attachments: `shared`](#42-arenas-and-attachments-shared)
  - [4.3 What a view is](#43-what-a-view-is)
  - [4.4 How views are rooted](#44-how-views-are-rooted)
  - [4.5 Mapped files](#45-mapped-files)
  - [4.6 Dynamic stacks and freezing](#46-dynamic-stacks-and-freezing)
  - [4.7 What can be frozen](#47-what-can-be-frozen)
  - [4.8 Frozen views and relative references](#48-frozen-views-and-relative-references)
  - [4.9 How mutation is rejected](#49-how-mutation-is-rejected)
  - [4.10 Views in another thread](#410-views-in-another-thread)
  - [4.11 The rules at a glance](#411-the-rules-at-a-glance)
- [5. The runtime model](#5-the-runtime-model)
  - [5.1 Arenas, attachments and their count](#51-arenas-attachments-and-their-count)
  - [5.2 Where frozen data lives: the dynamic stacks' budget](#52-where-frozen-data-lives-the-dynamic-stacks-budget)
  - [5.3 Release and reuse](#53-release-and-reuse)
  - [5.4 Stale and foreign handles](#54-stale-and-foreign-handles)
  - [5.5 Mapping a file: errors, prefaulting, truncation](#55-mapping-a-file-errors-prefaulting-truncation)
  - [5.6 Threads, contained workers, aborts and `thread_wait`](#56-threads-contained-workers-aborts-and-thread_wait)
  - [5.7 Ordering without atomics in the language](#57-ordering-without-atomics-in-the-language)
- [6. Interaction with existing features](#6-interaction-with-existing-features)
- [7. Platforms](#7-platforms)
- [8. The uses, in Goose](#8-the-uses-in-goose)
  - [8.1 Mapped column files](#81-mapped-column-files)
  - [8.2 Read-only data from main: dictionaries, metadata, plans](#82-read-only-data-from-main-dictionaries-metadata-plans)
  - [8.3 A radix-partitioned hash join](#83-a-radix-partitioned-hash-join)
- [9. The generated C](#9-the-generated-c)
- [10. What changes in the compiler and the runtime](#10-what-changes-in-the-compiler-and-the-runtime)
- [11. Measurements](#11-measurements)
- [12. Alternatives considered](#12-alternatives-considered)
- [13. Consistency with the specification and the other notes](#13-consistency-with-the-specification-and-the-other-notes)
  - [13.1 The deviations that remain](#131-the-deviations-that-remain)
  - [13.2 What the design adopts as proposed](#132-what-the-design-adopts-as-proposed)
  - [13.3 Additions that contradict nothing](#133-additions-that-contradict-nothing)
- [14. Test plan](#14-test-plan)
- [15. Documentation plan](#15-documentation-plan)
- [16. Phased plan](#16-phased-plan)
  - [Step 0: `resource<U>` (both tracks)](#step-0-resourceu-both-tracks)
  - [Phase 1: mapped files, attachments and views (#3)](#phase-1-mapped-files-attachments-and-views-3)
  - [Phase 2: dynamic stacks and frozen regions (#4)](#phase-2-dynamic-stacks-and-frozen-regions-4)
- [17. Open questions](#17-open-questions)
- [References](#references)

</details>

Design note, November 2026. Of what follows, only step 0, the
`resource<U>` handle, is implemented (spec §3.12). Step 0, phase 1 (mapped
files, attachments and views) and phase 2 (dynamic stacks and frozen
regions) are specified in section 16
closely enough to be built as written; the syntax is proposed for
implementation as it stands, and section 17 lists what is still open, each
with a recommended answer. The measurements of section 11 were taken
with the programs in `bench/shared_memory/`.

The question was how Goose threads can read the same memory without
copying it, as an analytical engine (more-fast-db, morsel-driven over
share-nothing workers) needs for two things: scanning column files from the
page cache, and the build side of a parallel hash join. Goose's rule is that
threads never share mutable memory (§11.2). The answer proposed here keeps
the rule by sharing only memory that nothing can write while anyone can see
it. That memory is a set of *regions*: a mapped file, or an array a thread
built and then *froze*. A region belongs to a *shared arena*. A thread reads
it through views rooted at its *attachment* to the arena, which the checker
holds to the attachment's scope, and the arena's memory is released when
its last attachment ends.

## 0. Decisions

1. **One feature, two kinds of region.** A *shared arena* holds immutable
   regions: mapped files (4.5) and frozen arrays (4.6). Everything else in
   the design is how a thread reaches a region, which is the same for both
   kinds (4.2 to 4.4), and when a region's memory is released (section 5).
2. **Handles are option C's `resource<U>`, as option C states it**
   ([owning_dynamic_data.md](owning_dynamic_data.md#future-option-c-opaque-api-resources)):
   one `u64` that code stores, copies, passes to workers, sends through
   queues and hands to the APIs of its kind, and nothing else: no
   dereference, arithmetic, comparison, or conversion to or from an
   integer. Bindings still define kinds of their own; the runtime is the
   binding for three: `resource<shared>` names an arena, `resource<mapping>`
   a mapped file in one, `resource<frozen<T>>` a frozen array of `T` in one.
   A handle owns nothing and keeps nothing alive (4.1).
3. **`resource<U>` is a step of its own**, step 0 of section 16: the
   foundation that this design and the messaging design (its events,
   `resource<event>`) both build on. The runtime's kinds pack a 40-bit
   arena serial, never reused, and a 24-bit region number into the `u64`,
   and the runtime aborts rather than reuse or wrap either (4.1).
4. **The root is an attachment.** `let sh = attach(h);` declares a `shared`,
   which is a root owner in the sense of §3.4: a local or global, never
   copied, returned, stored by value or sent. Every view is rooted at an
   attachment exactly, so §9's outlives rule keeps it inside the
   attachment's scope (4.4). `shared {}` makes a new arena and its first
   attachment.
5. **A view is a `const` slice**, `const T[:]`, and the `const T&` that a
   relative reference inside one loads. It needs no new kind of value:
   indexing, `for`, bounds-check elimination, `checkfree`, `bytes_of`,
   `print` and every library function over slices take it as they are
   (4.3).
6. **An arena lives while it is attached.** The runtime counts
   attachments, not values: the count changes at an attaching declaration
   and at its scope's exits, never when a handle or a view is copied. When
   the last attachment ends, the arena is released, and from then on its
   handles are stale: attaching one aborts with a diagnostic (5.1, 5.4).
   In the shape every engine has (main attaches, spawns, waits for its
   workers), the release point is the end of main's attachment, after its
   `thread_wait`s.
7. **One thread maps a file; every thread views it.**
   `sh.map_file(path)` maps a file once, read-only, for the whole process;
   `view<T>(sh, m, offset, count)` checks bounds and alignment once per view
   and is an ordinary slice afterwards (4.5). Views of mapped bytes are of
   *plain data* only, types every byte pattern of which is a value, because
   no program can keep other processes from writing a file (4.5, 5.5).
8. **No prefaulting or advice by default.** On the target machine, the
   first pass over a cached file through a mapping is already faster than
   `pread` into a buffer, and `MAP_POPULATE`, `MADV_POPULATE_READ` and
   `MADV_WILLNEED` made it slower or no faster (11.1). The runtime may
   advise later without any change to programs.
9. **Truncation ends the program, with a diagnostic.** Reading a mapped
   file that another process truncated raises SIGBUS. The fault handler
   names the file and the offset and ends the process, as it does for a
   data-stack overrun, in a contained worker too (5.5). Changing a mapped
   file's bytes in place is outside the guarantee; replacing the file by
   rename, as more-fast-db publishes tables, is safe, since the mapping
   keeps the old file.
10. **Frozen data is built in place, on a dynamic stack.** `dynamic_stack<T>`
    is the single-stack first step of §11.3's dynamic stacks and of
    owning_dynamic_data.md's option A ("bounded independent dynamic
    stacks"): a root owner whose one component, `items: T[>..]`, grows on a
    stack of its own, a slot of one budgeted reservation, instead of on one
    of the thread's data stacks. Its data never moves, it is released on its
    own, and its slots are a documented budget (4.6, 5.2). `sh.freeze(ds)`
    hands the slot to the arena without moving a byte and returns its
    handle; the checker treats it as a shrink of `ds.items` to empty (§5.1),
    so no reference or slice into it may be live. Afterwards `ds` is empty
    and can be filled again.
11. **What can be frozen**: arrays of fixed-size values that could cross
    threads, plus self-relative references and handles. Nothing that means
    something in one thread only: no plain references, slices, `in pool`
    references or index types (4.7). Self-relative references stay inside
    the region and load without a check, so a hash table linked by them is
    probed by `checkfree` code (4.8, validated in 11.6).
12. **Released regions are recycled, not unmapped.** When an arena is
    released, its frozen slots go back to the budget's free list with their
    pages, and new dynamic stacks take them from there; `trim_memory()`
    gives the pages back (5.3). Sixteen threads unmapping at the same moment
    took 80 ms where one alone took 4.8 ms; keeping the slots took nothing
    (11.2).
13. **Aborts release what a thread holds.** The runtime keeps each
    thread's attachments and dynamic stacks on a stack of its own, so a
    contained worker's abort releases them, as it releases the worker's data
    stacks, before `thread_wait` returns. The regions a worker froze stay in
    their arena (5.6).
14. **No atomics, locks, memory orderings or `unsafe` in the language.**
    The counts and the region tables are the runtime's. Every way a handle
    can reach another thread already orders the writes that built the
    region before the reads of it (5.7).
15. **Two deviations from the specification remain**, each for a reason
    section 13 gives: a third kind of memory, shared regions, beside the
    data stacks and static data; and the runtime's count of attachments.
    Everything else adopts what option C, §11.3 and option A propose.
16. **Step 0 and two phases.** Step 0: `resource<U>`, for both tracks.
    Phase 1 (#3): `shared`, `attach`, mapped files and their views, on POSIX
    and Windows. Phase 2 (#4): `dynamic_stack<T>`, its budget, `freeze` and
    frozen views (section 16).

## 1. What the feature is for

### 1.1 The invariant

*No thread can write memory that another thread can read.* Shared memory is
immutable for as long as anyone can see it, and no view outlives the memory
it views. The compiler proves the second half with roots (§9.2); what only
the runtime can know (whether a handle still names live memory, whether a
view lies inside its region) the runtime checks, and a failed check is a
diagnostic, never undefined behavior. Nothing in it is a convention a
program must follow.

Goose already has one kind of shared memory: static data. String literals
and `const` globals with compile-time initializers are emitted once, read
by every program instance, and provably never written, because a slot that
holds a view of them must say `const`
([string_constants.md](string_constants.md), §9.5). What this design adds is
static data whose lifetime is not the whole program, and whose contents a
running thread chose: a file the program opened, or an array a worker
computed.

### 1.2 The uses

**Mapped column files.** A more-fast-db table is a directory of column
files. Each holds its row groups' segments back to back, each padded to
8 bytes; a fixed-width segment is a raw little-endian array, and a VARCHAR
segment is `u32` codes followed by the row group's dictionary
(more-fast-db's `docs/format.md`). Today every worker `pread`s each morsel's
segments into buffers of its own (its `docs/source.md`). The engine wants to
map each file once and read `const i64[:]`, `const i32[:]`, `const u32[:]`
and `const u8[:]` views of it straight from the page cache.

**A radix-partitioned hash join over W share-nothing workers.**

1. Each worker scans build-side morsels and writes its rows into P
   partitions in memory it owns.
2. Freeze, and a barrier.
3. Any worker takes the task "build partition p". It reads *every*
   worker's frozen partition-p rows, builds partition p's hash table in
   memory of its own, and freezes the table.
4. A barrier.
5. Every worker probes its probe-side morsels against all P frozen tables.

**Read-only data from main to every worker**: per-morsel string
dictionaries, metadata such as the parsed manifest, and plans.

Section 8 writes all three out under the proposed design.

### 1.3 The constraints

Restated as tests the design has to pass:

1. **By construction.** The invariant of 1.1 holds for every program that
   compiles, without an `unsafe`, an annotation or a protocol the program
   has to keep.
2. **It fits Goose.** Handles are option C's `resource<U>`; views are tied
   to roots as references are; nothing in the language synchronizes;
   ownership is a declaration's scope, as it is for every other kind of
   storage.
3. **Zero copy, no per-element cost.** A loop over a view compiles to the
   loads a loop over a slice compiles to, and can be `checkfree`.
4. **Zero cost to everyone else.** A program that does not use the feature
   compiles to the C it compiles to today.
5. **Portable.** POSIX (Linux, macOS) and Windows, the in-process TinyCC
   backend, and a fallback where a file cannot be mapped.

## 2. The boundary today

### 2.1 Why queues and spawn arguments copy

A Goose reference is a raw address into the memory of one program instance
(§1.2): a data stack of the thread that made it, or static data. The
outlives rule (§9.1) is checked along the compile-time call path of one
thread program, from the scopes that program opens; it says nothing about
another thread's scopes. A reference handed to another thread could
therefore point into a stack that its owner shrinks, grows over or releases
when it exits, and the owner could write the pointee while the other thread
reads it, which is a data race. So only **flat** values cross (§1.1: no
references, slices or relative references at any depth), and they cross by
copy: `thread_spawn` packs the arguments and the worker's globals into an
image that the worker's entry thunk unpacks onto its own stacks, and `qput`
copies its value's image into a node that `qget` copies out
(implementation.md §6.8). The compiler says so in these words today:

```text
error: queue elements must be flat (§11.2), not i64[:]
error: thread_fn parameters must be flat (§11.2), not const i64[:]
```

A copy is cheap, because a Goose value is contiguous, and it gives the
receiver a value that is its own. What it cannot give is two threads
reading the same large structure: each needs its own copy.

### 2.2 Why an `extern fn` cannot return a slice

§7.10: "A return is one scalar or flat fixed-size value by value, or
nothing; references, slices and builders can only be parameters." A slice
needs a root, a variable whose scope bounds the memory it points into, and C
memory has none: the checker cannot know how long C keeps it, whether C or
another thread writes it, or how long it is. A slice *parameter* has the
caller's root, and C "must not retain a borrowed argument beyond the call".
So the obvious binding of `mmap` does not compile:

```text
error: extern fn give cannot return u8[:]: nested references and slices do not cross
```

Option C of [owning_dynamic_data.md](owning_dynamic_data.md) draws the same
line from the other side: a `resource<FileMapping>` returned by a binding
would be an opaque value, "not an implemented way to obtain a native pointer
as a Goose reference", and "direct mapped views would need a separate design
connecting their bounds and lifetime to the resource". This note is that
design. The missing root is the attachment of section 4.4: a variable whose
scope the checker knows, and whose memory the runtime keeps valid and
read-only for that long.

### 2.3 What a program does instead, and what it costs

* **A copy per worker.** more-fast-db's source gives each worker buffers as
  large as a column's largest segment and fills them with one `pread` per
  column per morsel. Measured in section 11.1, summing a 2 GB `i64` column
  from the page cache this way runs at 9.5 GB/s on one thread and 73 GB/s on
  16, against 16.4 and 143 GB/s through a mapping on its first pass, and
  20.4 and 158 GB/s on later passes. `read_file`, which reads the whole file
  into one array before anything can use it, is 2.2 GB/s: a single-threaded
  0.86 s read of 2 GB, then the sum.
* **A copy per reader.** A structure that every worker reads, such as a
  join's hash tables, can only reach the workers as a copy each: through
  queues, or by each worker building it again. For the join of section 8.3
  with a 16M-row build side (about 770 MB of tables) and 16 workers, that is
  12 GB of copies, and as much memory.

### 2.4 What Goose already has

The pieces this design is made from:

* **`const` views** (§9.5): a `const T[:]` cannot write its elements, a
  slot holding one must be declared `const`, and `const` is never dropped
  implicitly. Static data is shared safely on exactly this basis.
* **Roots** (§9.2): every view has a variable that bounds its lifetime, per
  specialization, with no annotations.
* **Root owners** (§3.4, [root_structs.md](root_structs.md)): a class of
  value owned only by a local or global declaration, never copied, passed
  or returned by value, never a temporary, never sent to a worker, with a
  scope-exit action (restoring its components' stacks) that every exit
  runs. An attachment and a dynamic stack are root owners.
* **Byte views** (`bytes_of`, [serialization.md](serialization.md)): a view
  of typed storage at another type, which is never writable.
* **Self-relative references** (§3.9): links that stay inside one root
  array and mean the same wherever the array is.
* **Contained workers** (§11.2): an abort that ends one worker and releases
  what a return would, with the runtime doing the releasing.
* **Option C's `resource<U>`**: an opaque fixed-size handle that a program
  can only copy, store and pass back to the API that made it.
* **§11.3's dynamic stacks and option A's "bounded independent dynamic
  stacks"**: stacks made at run time, each released on its own, out of a
  budgeted reservation. A dynamic stack is the memory a frozen array is
  built in.

## 3. The model

```text
            thread A (main)                         thread B: thread_fn w(h, col)

  let sh = shared {};   ─────────┐ arena #17, attached 1
  let col, ok = sh.map_file(p);  │   region 1: mapping of p
  thread_spawn(w, sh.handle, col)│                      let sh = attach(h);   attached 2
                                 │                      let xs = view<i64>(sh, col, off, n);
                                 │   region 2: frozen   var ds = dynamic_stack<Row> {};  (private)
                                 │      Row[] ◄──────── qput(sh.freeze(ds));            (now shared)
  let rows = sh.view(qget<…>()); │                      }   // end of B's sh: attached 1
  thread_wait(id);               │
  }   // end of A's sh ──────────┘ attached 0: released; the mapping unmapped,
                                   region 2's slot to the free list
```

* A **shared arena** is a set of immutable regions and a count of
  attachments. It is runtime state, outside every thread's data stacks.
* A **region** is a mapped file, or the stack of a dynamic stack that was
  frozen. It never moves, never changes, and is released only with its
  arena.
* A **handle** (`resource<U>`) names an arena or a region in one. It is a
  flat value: one `u64`.
* An **attachment** (`shared`) is a declaration in one thread. While it is
  in scope, its arena cannot be released, and views of its arena's regions
  can be made through it, rooted at it.
* A **view** is a `const` slice into a region.
* A **dynamic stack** (`dynamic_stack<T>`) is a private, growable array on
  a stack of its own, a slot of a budgeted reservation, that no other
  thread can see until it is frozen.

## 4. Syntax and type rules

The proposal adds five names that resolve as types (`resource`, `shared`,
`mapping`, `frozen`, `dynamic_stack`) and six builtins: `attach`, and
`handle`, `map_file`, `size`, `view` and `freeze`, which take an attachment
first and so read as its members (`sh.map_file(path)`, by UFCS, §7.1). None
of them is a keyword. Like the builtin functions they are found only where
nothing the program declares has the name, so an existing variable, field
or type named `shared` or `view` keeps its meaning, and `::name` reaches the
builtin past a namespaced declaration (§11.1). There is no new syntax:
every form below parses today. A call with a type argument is written as a
function call, `view<i64>(sh, m, offset, count)`, as `qget<T>()` and
`from_bytes<T>(b)` are, because a member call takes no type arguments
(Appendix D).

### 4.1 `resource<U>`, the first step

`resource<U>` is option C of owning_dynamic_data.md, adopted as option C
states it. This section stands on its own: it is step 0 of the phased plan
(section 16), which lands before either track needs it, and the messaging
design (`docs/design/inboxes_select.md`, in review beside this note) builds
its events, `resource<event>`, on it as this design builds arenas and
regions.

**What it is.** A fixed-size value, internally one `u64`, that names
something code does not reach into: a GPU buffer, a native byte buffer, a
file mapping, an arena. `U` is a tag identifying the kind of thing named.
What the sixty-four bits mean is the kind's binding's business; Goose code
never sees them.

**What code can do with one**, which is option C's list and nothing more:
store it wherever a fixed-size value can be (locals, globals, aggregate
fields, array elements, payloads, arguments, results), copy it, and pass it
to an API that accepts its kind. Copying it copies the name; it does not
duplicate, or keep alive, what the name refers to. Code cannot dereference
a handle, compute with it, compare it (`==`, `!=` and the orderings are all
errors), hash it, or convert it to or from an integer (`as` and `as!` reject
both directions), so no code can make a handle that its kind's binding did
not hand out. Nothing in this design needs to compare handles: a program
that must know whether a slot holds one keeps a `bool` beside it. If a use
for comparison appears, it is a named builtin, not an operator (section 17).

**What follows from its being a fixed-size value**, which option C implies
without spelling out:

* It is flat (§1.1), so it can be a `thread_fn` parameter or a queue
  message, and a struct holding one is flat if the rest of it is.
* Its default is the value of all bits zero, which names nothing, for every
  kind: a binding never hands out zero. A literal's `..`, a global declared
  with its type alone (`var g: resource<mapping>;`) and a missed `qpoll`
  give it.
* It has a text form, as every value does (§3.7), which is its type alone:
  `print` of a handle writes `resource<mapping>`. A message holding a handle
  can be printed, and the text shows that a handle is there without showing
  its bits.
* It has no image: its bits mean something only to the binding's state in
  one process, so `to_bytes`, `bytes_of` and `from_bytes` reject a type
  holding one, as they reject plain references.
* A struct holding one has no `==`, since that would compare the handle.

**Kinds.**

| Kind | Its binding | Made by | Taken by |
|---|---|---|---|
| `resource<U>`, `U` a tag type of a binding (option C's `GpuBuffer`) | the binding's C | the binding's `extern fn`s that return one | the binding's `extern fn`s |
| `resource<shared>`, an arena | the runtime | `sh.handle` (4.2) | `attach` |
| `resource<mapping>`, a mapped file in an arena | the runtime | `sh.map_file(path)` (4.5) | `view<T>`, `size` |
| `resource<frozen<T>>`, a frozen array of `T` in an arena | the runtime | `sh.freeze(ds)` (4.6) | `view` |
| `resource<event>`, the messaging design's events | the runtime | as that design specifies | as that design specifies |

`mapping` and `frozen<T>` name kinds, not values: they are written only as
the argument of `resource`. A binding's tag is any type it declares for the
purpose (`struct GpuBuffer {}`); its values are never made.

**At the C boundary** a handle crosses an `extern fn` as `uint64_t`, by
value, as a parameter or as the result (§7.10 gains the shape). A binding's
kind is made and read by its C, as option C says. The runtime's kinds are
made only by the runtime, their one binding: an `extern fn` may take one,
and C then sees its sixty-four bits (which is how C names an event of the
messaging design to `gs_event_signal`), but it may not return one, nor a
value holding one, so no C function hands Goose a handle of the runtime's
that the runtime did not make.

**Cleanup**, which option C leaves unresolved, stays unresolved for the
kinds bindings define. For the runtime's kinds of this design it needs no
rule about handles at all: a handle owns nothing, so copying, storing or
dropping one does nothing, and what holds memory is an attachment (4.2),
which ends with its scope.

**The runtime's encoding** of `shared`, `mapping` and `frozen<T>`:

```text
bits 63..24   the arena's serial, 1 to 2^40 - 1, never reused
bits 23..0    0 for the arena itself, else the region's number in it, 1 to 2^24 - 1
```

`GS_RES_SERIAL_BITS` (40) and `GS_RES_REGION_BITS` (24) name the split in
`runtime.h`, with a static assertion that they add up to 64, and the
runtime checks it both ways. Making the 2^40-th arena, or the 2^24-th
region of one arena, aborts ("shared arena serials are used up", "a shared
arena holds at most 16,777,215 regions") instead of wrapping. And every
handle the runtime is given is decoded against its tables, so a serial that
names no live arena is stale (5.4), and a region number past its arena's
count is a defect the runtime reports. Since serials are never reused, a
stale handle cannot come to name a newer arena. 2^40 arenas is one every
microsecond for 12 days, or a thousand a second for 35 years; 2^24 regions
in one arena is room for the join of section 8.3 at any worker count many
times over. Every kind of the runtime's, the messaging design's events
included, documents its encoding under the same rule: a stale value never
names a newer resource.

Handles are weak. Holding one keeps nothing alive; it is a way to *attach*
an arena (4.2) and to name one of its regions in a view (4.3).

### 4.2 Arenas and attachments: `shared`

`shared` is a builtin root-class type (§1.1, §3.4). A value of it is an
**attachment** to an arena, and it is made only by an owning declaration,
local or global:

```goose
let sh = shared {};          // a new arena, and this declaration's attachment to it
let sh2 = attach(h);         // h: resource<shared>; another attachment to h's arena
let h2 = sh.handle;          // resource<shared>: sh's arena, for other threads
```

Both forms construct the attachment directly at the declaration, as a root
struct's literal does. `attach(h)` aborts if `h` is the zero handle or
names an arena that has been released (5.4). An attachment follows every
rule of root owners: it is not copied, assigned whole, passed or returned by
value, used as a temporary, stored by value in a struct, array or payload,
or passed to `thread_spawn` or a queue. Functions take it by reference,
`sh: shared&`, and an unannotated binding of one borrows it. A worker
cannot use a global attachment of main's, since a worker cannot use a root
global (§11.2); it attaches the handle instead.

The attachment's scope is what keeps the arena alive. Its exits (falling
off the end, `break`, `continue`, `return`, `return … from`) end the
attachment, in reverse declaration order with the restores and `defer`s of
its scope, and the runtime ends it too when a contained worker aborts
(5.6). Two attachments to one arena in one thread are independent; each
counts.

### 4.3 What a view is

A view is an ordinary read-only slice of a region: `const T[:]`, with the
`data, len` layout of every slice (C.2). The builtins that make one take
the attachment first:

```goose
let col = view<i64>(sh, m, offset, count);  // a mapping's bytes, as `count` i64s from byte `offset`
let rows = sh.view(r);                      // a frozen array, whole: r: resource<frozen<Row>>
```

Everything a program does with a slice it does with a view: index it, slice
it again (`rows[a..b]`), iterate it, pass it to a function taking `T[:]` or
`const T[:]`, keep it in a local or in a field or element declared
`const`, take `bytes_of` it, print it, compare it, copy its elements out. A
self-relative reference read out of a frozen view loads as a `const T&`
(4.8). There is no view type, no view-specific operation after the view is
made, and no cost per element: the check a view makes, that it lies inside
its region and is aligned, is made once, when it is made (4.5).

### 4.4 How views are rooted

Every view is rooted, exactly, at the attachment it was made through: at
`sh`, or, where `sh` is a reference parameter, at the class of the
attachment that the caller passed (implementation.md §3.4), as a slice of a
pool is rooted at the pool. The attachment's storage is taken to be every
region of its arena. Exact means here what it means for any root, that the
target lies in the root's own storage, and not that two views of one
attachment view one array: an attachment is never an array receiver, so
the rules that read an exact root as "this array" (`index_of`,
`range_index`, a slice pool's `free_slice`) never meet one. Two
consequences follow, and they are the whole of the lifetime rule:

* **A view cannot outlive its attachment**, by §9.2 as it stands: it is
  not stored where it would (a global, a holder declared outside, a queue
  message, which is not flat anyway), not returned past the attachment's
  scope, and not live across a scope exit that ends the attachment. While
  the attachment is in scope the runtime keeps the arena, so the region
  stays mapped and unchanged. So no view outlives its memory.
* **An attachment is a read-back candidate** (§9.5) for every type a view
  can have: plain data, and the types that can be frozen (4.7). A view
  stored in a container and read back out may therefore be rooted at an
  attachment in scope, and is held to its scope, rather than to a
  candidate that happens to hold its element type by value. Without this,
  a view read out of a holder could be given a root that outlives the
  attachment. This is what `StaticCanContain` already does for static data,
  whose storage likewise holds what no variable declares. The cost is
  precision: in a function with an attachment in scope, a slice read back
  out of a holder that the store record cannot resolve may be held to the
  attachment's scope where it is not in fact a view.

A view is never writable, whatever the attachment's binding (4.9).

### 4.5 Mapped files

```goose
let m, ok = sh.map_file(path);        // resource<mapping>, bool
let m, ok = sh.map_file(path, why);   // and on failure appends the reason to why, a growable u8 array
let n = sh.size(m);                   // the file's size in bytes, as it was when mapped
let xs = view<T>(sh, m, offset, count);
```

`map_file` opens the regular file `path` (UTF-8, as the `os` module's paths
are) read-only, maps the whole of it into the arena and returns its handle
and `true`. It returns the zero handle and `false`, and maps nothing, for a
path that is not a regular file (missing, a directory, a device, a FIFO), a
path holding a NUL byte, a file the program may not read, a file larger
than 2^48 bytes (§10.4), and a mapping the system refuses. The reason is
the system's message where there is one. An **empty file** maps
successfully, to a mapping of size 0: a table with no row groups has empty
column files (more-fast-db's format), and an empty file is not an error.

`view<T>(sh, m, offset, count)` is the view of `count` elements of type `T`
at byte `offset` of the mapping. Its rules:

* **`T` is plain data**: a type every byte pattern of whose size is a
  value. The integer and float scalars are plain data, and so are fixed
  arrays of plain data and structs whose fields are all plain data (pads
  allowed, since they are never read). Nothing else is: not `bool` (only 0
  and 1 are values), not an enum (its tag has a range), not a limited array
  (its length is at most its capacity), not a `varint`, not a reference of
  any kind, an index type or a handle. Any other `T` is a compile error that
  names the part of `T` at fault. The reason is §9.4: external bytes must be
  validated before they become a Goose value, and for plain data there is
  nothing to validate, *now or later*. That matters because a mapped file
  can change under the program (5.5); a verifier's verdict on a tag or a
  link would not survive that, and a plain value cannot be invalid.
* **Alignment.** `offset` must be a multiple of `T`'s alignment, the width
  of the widest scalar in `T` (1, 2, 4 or 8). A mapping starts on a page,
  so this aligns the view's address. Goose's loads are all unaligned-safe
  (C.2), so this is not needed for safety. It is required because the
  formats that are mapped align their arrays (more-fast-db's segments are
  8-byte aligned), a misaligned offset is therefore a corrupt directory, and
  the check costs one `and` per view. A constant offset that is misaligned
  is a compile error.
* **Bounds.** `0 <= offset`, `0 <= count`, and
  `offset + count * sizeof(T) <= sh.size(m)`, checked without overflow.
  A view of `count` 0 is empty and valid at any offset up to the size.
* **The handle.** `m` must name a mapping of `sh`'s arena; the zero handle
  and a handle of another arena abort (5.4).

A view that fails a check aborts, with a message naming the mapped file,
the view's type, offset and count, and the file's size. These checks are
aborts of their own in §9.3's list, like `range_index`'s; they are not the
index and slice checks that `checkfree` counts (§7.14), so a `checkfree`
function may make views. The bounds-check pass knows that a view's length is
its `count` (section 6).

`view<u8>(sh, m, 0, sh.size(m))` is the whole file's bytes, which is also
what `from_bytes` takes: a serialized image in a mapped file is verified and
copied in by `from_bytes<T[>..]>(view<u8>(sh, m, 0, sh.size(m)))` with one
copy and no read.

### 4.6 Dynamic stacks and freezing

```goose
var ds = dynamic_stack<Row> {};    // a grow-only array on a stack of its own
ds.items.push(Row { key: k, payload: v });
fill(ds.items);                    // fn fill(out: Row[>..]&): any code that grows an array
let r = sh.freeze(ds);             // resource<frozen<Row>>; ds.items is empty again
let rows = sh.view(r);             // const Row[:], rooted at sh
```

`dynamic_stack<T>` is the first step of the dynamic stacks that §11.3 plans
and that owning_dynamic_data.md's option A ("bounded independent dynamic
stacks") works out: one stack of its own, made at run time. It is a
builtin root-class type with one component, `items: T[>..]`, a grow-only
array like any other and the only value on its stack, as the resizable on
top of a data stack is the only one growing there (§1.3). What is new is
the memory under it: a slot of the dynamic stacks' budget (5.2), instead of
one of the thread's data stacks. `dynamic_stack<T> {}` constructs one at an
owning declaration; the literal takes no fields. `T` is any fixed-size type
a grow-only array may hold.

Until it is frozen a dynamic stack is private to its thread, as every array
is: `ds.items` grows, shrinks where §5.1 allows, is indexed, written,
sliced and passed to functions taking `T[>..]&` or `T[:]`, and `ds` follows
the rules of root owners (not copied, sent or returned; taken by reference
as `dynamic_stack<T>&`). A dynamic stack holds a resizable component, so it
cannot be live across a call into a recursive cycle (§7.8), as no root
owner with one can. On its own, a dynamic stack is little more than a local
`T[>..]` with a stack to itself; what it adds now is that its stack can be
handed over.

`sh.freeze(ds)` ends the private phase:

* **The check is a shrink.** Freezing takes `ds.items`'s elements away
  from `ds`, so it is checked as `ds.items.clear()` is (§5.1): it is an
  error if any reference or slice into `ds.items` is live after the call,
  or held by a live holder, including through calls, which record what they
  shrink. So no writable view of the elements survives into the time they
  are shared, and no view of `ds.items` sees the new, empty array as the old
  one. `T` must also be freezable (4.7), which is checked at the call.
* **References to the whole array survive it.** §5.1 lets a reference to a
  whole array, as against one into its elements, stay live across a
  shrink, and a freeze keeps that: a `T[>..]&` to `ds.items` taken before
  the freeze, in a variable, a holder or a caller's parameter, still refers
  to `ds.items` afterwards, which is then empty, as after a `clear()`, and
  pushing through it grows `ds.items` on its fresh slot. Nothing such a
  reference can reach is in the frozen slot, because it names the dynamic
  stack's own header and stack control block, never a slot (5.2). What is
  new is that the array's base has moved, so codegen reloads it wherever it
  had cached it (section 9).
* **What it does.** The slot holding `ds.items`'s elements, exactly
  `ds.items.len` of them, becomes a frozen region of `sh`'s arena; its
  handle is the result. Nothing is copied. `ds` is left with an empty
  `items` on a fresh slot, its header and stack starting there, and can be
  filled and frozen again; at its scope's exit, an unfrozen slot goes back
  to the free list (5.3).
* **The arena.** `sh` can be any attachment, in any thread; the region
  joins that attachment's arena and lives as long as the arena does.

Only a dynamic stack can be frozen. An ordinary array lives on a data stack
beside other values and cannot be handed over; a program that wants to
publish one copies it onto a dynamic stack (`ds.items.append(xs)`) and
freezes that.

**How this fits option A.** Option A proposes "a runtime-sized collection
in which each element owns an independently growing stack" and asks three
things of it: stable data, independent release and a budgeted reservation.
A single dynamic stack has each of them, and the parts of the API that
touch them (`items`, `freeze`, the scope exit, the budget) are chosen for
that. The table goes through those three and what option A says of limits,
reference safety and identity:

| Option A's direction | `dynamic_stack<T>` |
|---|---|
| **Stable data**: "growth within an inner stack's reservation preserves its element addresses" | `items` grows by bumping its stack's top, and no element ever moves: freezing hands the elements over where they are, and `items` starts again, empty, on a fresh slot |
| **Independent release**: "closing a document decommits its pages and recycles its region slot independently of other documents" | the slot is released at the declaration's scope exit, or handed by `freeze` to an arena and released with it, in either case apart from every other dynamic stack. Its pages are decommitted by `trim_memory()` rather than at once, because releases come in bursts and the system serializes them (5.3, 11.2) |
| **A budgeted reservation**: "the configured total stack count must satisfy N * (R + G) + H <= B" | every slot comes from one reservation of B bytes in slots of R + G, with N documented, and a dynamic stack that finds all N in use aborts with the budget's numbers (5.2) |
| **Explicit limits**: "the configured bounds permit explicit checks rather than relying on an overflow guard to abort the process" | `ds.items.check_length(n)` checks a count against R before growing, as it checks against a data stack's reservation; growth that goes past R ends the program at the guard, as a data stack's does |
| **Reference safety**: "closing a document releases its storage, so it must be forbidden while references or slices into it can still be used" | views of `ds.items` are rooted at `ds` (§9.2), so none outlives its scope, and `freeze` is checked as a shrink |
| **Identity**: "an outer table index is not a permanent document identity if slots can be removed and reused; use a stable handle or another explicit identity policy" | no slot number is ever exposed; a frozen slot is named by a `resource<frozen<T>>` whose serial is never reused (4.1), and a view of it is made only through a live attachment, so a stale handle reaches no memory |
| **Recoverable limit errors**: "opening document 257 returns a recoverable limit error" | not in v1: a declaration cannot fail recoverably. It belongs with option A's collection, where the limit is a count the program chose (section 17) |

Option A proper, a collection whose every element is a dynamic stack,
generalizes this one instead of sitting beside it: `dynamic_stack<T>` is
the collection of one, and the collection's elements would draw slots from
the same budget, freeze as this one does and be released one by one. The
join of section 8.3 partitions onto one dynamic stack per worker, because a
dynamic stack is a declaration and the number of partitions is known only
at run time; with the collection it would use one per partition. A task with stacks of its own
([coroutines.md](coroutines.md) 6.1) would draw its block of stacks from the
same budget.

### 4.7 What can be frozen

A dynamic stack holds any fixed-size type a grow-only array may. To be
frozen, its `T` must also be **freezable**: holding, at no depth, anything
whose meaning depends on the thread that made it:

| May appear in `T` | Why |
|---|---|
| scalars, `bool`, enums in fixed mode, fixed and limited arrays, structs of these | flat values mean the same in every thread (§1.1) |
| self-relative references, `T&<w>` and `T&<w>?` | they point within their own root array (§3.9), which is the region, and a region never moves |
| handles, `resource<U>` | a handle's bits name the same thing in every thread of the process (4.1) |

| May not | Why |
|---|---|
| plain references, slices, optionals `T?` of a plain reference | addresses into the freezing thread's stacks, or into regions it could not keep alive |
| `in pool` references | measured from a global pool's base, and each thread has its own copy of the global (§11.2) |
| index and bound types, `u32 in a` | proven against one thread's copy of `a` (§3.11), which other threads' copies need not match |
| root owners, `shared`, `dynamic_stack<T>` | not values that can be stored (§3.4) |
| variable-size values | a dynamic stack's elements are fixed-size in v1 (section 17) |

Apart from the self-relative references, this is the set of types that may
cross threads today: frozen data is data another thread will read, and the
rule for what it may hold is the rule for messages, with the one exception
that relative references survive because nothing is copied. A wrong `T` is
an error at the `freeze`, naming the field path and the reason.

### 4.8 Frozen views and relative references

`sh.view(r)` for `r: resource<frozen<T>>` is the whole frozen array as a
`const T[:]`, rooted at `sh`. Its length is the length `ds.items` had when
it was frozen. `view<T>(sh, r)` with `T` written is accepted where it is the
handle's `T`, and an error otherwise.

Self-relative references inside frozen data behave as they do in any array
read through a read-only path (§3.9, §9.5):

* **Loading** one, `rows[i].next`, gives a `const T&` (or `const T?`),
  rooted at `sh` exactly, and costs an addition, with no check: the store
  that made the link was checked to stay within the dynamic stack's array,
  and the region does not change afterwards. A chain is followed by rebinding
  within that root, `e .= e.next`, as in any array.
* **Storing** one is impossible, since the view is read-only. Links are
  made before freezing, under the same-root rule (both ends in `ds.items`),
  and `self` works as in any literal.
* **A link left past the end.** §5.1 does not count a value linked by
  relative references alone as a holder, so a `pop` may leave an element's
  link pointing past the array's end, at the element popped, which reads as
  that element afterwards (type-safe reuse, §9.4). A frozen region keeps
  every byte its dynamic stack wrote, up to its high-water mark, until the
  arena's release, so such a link reads the same element after freezing as
  before. Links can only point at bytes the dynamic stack itself wrote, so a
  slot recycled from another type's (5.3) shows none of the old bytes.
* **Copying** elements that hold self-relative references out of a view is
  rejected (`append`, by-value copies), as it is from any array (§3.9);
  binding them by reference is how they are read.

So a hash table whose chains are self-relative links is built by one worker
and probed by all of them with no check per probe beyond the bucket index,
which a `%` by the table's length proves (section 8.3; the loops compile
as `checkfree` today over `const` slices, 11.6).

### 4.9 How mutation is rejected

* **By type.** A view is `const T[:]`; every write through it, and through
  the `const T&` its links load, is a compile error (§9.5), as is storing
  it in a slot not declared `const`. `const` is never dropped implicitly, so
  no path makes a view writable.
* **By ownership.** A dynamic stack is the only writable access to a
  region, and it is a root owner in one thread, which no other thread can
  name. Freezing is checked as a shrink, so no writable view of a dynamic
  stack's elements is live once they are shared (4.6). After freezing, the
  dynamic stack no longer owns the region, and nothing it or a reference to
  its `items` can reach lies in the region (4.6, 5.2).
* **By the hardware**, as a backstop. A mapping is read-only (`PROT_READ`,
  `PAGE_READONLY`), so a write that a defect in the compiler let through
  faults, and the fault handler reports it. In a debug build (`GS_DEBUG`),
  `freeze` makes the region read-only too. A release build does not, because
  the call costs about 20 µs per MB with other threads running (11.3), and
  the checker's proof is what the guarantee rests on, as it is for static
  data, which is `const` in C for the same backstop.

### 4.10 Views in another thread

A thread that did not make a region gets its views in three steps: receive
the handles (spawn arguments, queue messages, a global copied at spawn, or
a frozen region that holds them), attach the arena once, and make views
through the attachment.

```goose
thread_fn reader(arena: resource<shared>, col: resource<mapping>, n: i64) {
    let sh = attach(arena);                 // once, for as long as the worker reads
    let xs = view<i64>(sh, col, 0, n);      // as many views as it likes, no count changed
    print(sum(xs));
}
```

Attaching costs an atomic increment (11 ns alone, 1.0 µs with 16 threads
attaching the same arena at once, 11.4), so a worker attaches at its start,
or at the start of a phase, and passes `sh: shared&` down; views are free
of atomics.

### 4.11 The rules at a glance

Compile-time:

| Rule | Where it comes from |
|---|---|
| a handle is stored, copied and passed to its kind's APIs, and is not dereferenced, computed with, compared, hashed, converted or serialized | option C (4.1) |
| an `extern fn` takes a handle of the runtime's kinds but does not return one | 4.1 |
| a view does not outlive its attachment | §9.2, unchanged; the attachment is the root (4.4) |
| a view is never written | §9.5, unchanged; views are `const` (4.9) |
| a view does not cross threads or queues | §11.2, unchanged; a slice is not flat |
| an attachment or a dynamic stack is not copied, returned, stored by value, sent, or a temporary | §3.4's root owners, unchanged |
| `view<T>` of a mapping takes plain data only, at an aligned constant offset | 4.5 |
| `dynamic_stack<T>` takes a fixed-size `T` | 4.6 |
| `freeze(ds)` leaves no reference or slice into `ds.items`' elements live; a reference to the whole array may stay live and sees it empty, as after a shrink | §5.1's shrink rule (4.6) |
| `freeze(ds)` takes a freezable `T` | 4.7 |
| no attachment or dynamic stack is in scope at a coroutine's suspension point | [coroutines.md](coroutines.md) R1, extended (section 6) |

Run-time (each a diagnostic; §9.3's list gains them):

| Check | Result |
|---|---|
| `attach` of the zero handle, or of a released arena | abort |
| a view through an attachment of another arena, or of the zero handle | abort |
| a mapping view out of bounds or misaligned | abort |
| the 2^40-th arena, or the 2^24-th region of one arena | abort (4.1) |
| a dynamic stack when every slot of the budget is in use | abort, naming the budget and the flag that raises it (5.2) |
| a dynamic stack growing past its slot's reservation | ends the program, as a data-stack overrun does |
| a mapped file truncated under its mapping, or unreadable (SIGBUS, `EXCEPTION_IN_PAGE_ERROR`) | ends the program (5.5) |

## 5. The runtime model

### 5.1 Arenas, attachments and their count

An arena is a runtime record: a serial number that is never reused, a
count of attachments, a lock, and an append-only table of region records
(base, byte length, kind, and for a mapping its path). It lives outside
every data stack, in memory the runtime allocates for itself, as it does for
queues (§1.2).

* `shared {}` creates an arena with a count of 1 and registers it in a
  process-wide table from serial to arena.
* `attach(h)` looks `h`'s serial up under that table's lock; if the arena is
  there and its count is above zero, it increments the count, and otherwise
  it aborts (5.4).
* An attachment's end decrements the count. The decrement that reaches zero
  removes the arena from the table, under its lock, and releases it (5.3).
  An arena whose count reached zero cannot be attached again, so it cannot
  come back after its release.

This is a count of attachments, not of values. It changes at an attaching
declaration and at its scope's exits: never when a handle is copied,
stored, sent or dropped, and never when a view is made or copied. A worker
that attaches once at its start and ends after its last morsel changes it
twice.

When is an arena released? When no thread has it attached. In the shape of
every program in section 8 (main attaches, starts workers, waits for each
of them with `thread_wait`, then leaves its attachment's scope), that is a
fixed point: main's scope exit, after the waits, since `thread_wait` returns
only once a worker's attachments have ended (5.6). A program that hands an
arena from one worker to another must keep an attachment until the
receiver has attached. Getting that wrong is a liveness error that the
runtime reports (the receiver's `attach` aborts), never a dangling view.

### 5.2 Where frozen data lives: the dynamic stacks' budget

A dynamic stack's elements live in a **slot** of the dynamic stacks'
**budget**, which is option A's budgeted reservation made concrete:

* **One reservation.** The first time a program needs a slot, the runtime
  reserves `GS_DYNAMIC_BUDGET` bytes of address space (B: 16 TB by default,
  set with `--dynamic-budget`, as `--stack-reserve` sets a data stack's
  reservation) as one range, inaccessible (`PROT_NONE` on POSIX,
  `MEM_RESERVE` on Windows), and divides it into slots of R + G bytes: R
  usable, the data stacks' `GS_STACK_RESERVE` (2 GB by default), and a
  guard gap G, `GS_STACK_GAP` (1 MB), that stays inaccessible. So there are
  N = B / (R + G) slots, 8,188 by default: option A's N * (R + G) + H <= B,
  with H, the slots' records, held apart from the reservation in memory the
  runtime allocates for itself. A program that makes no dynamic
  stack reserves nothing. Where the platform refuses the range, it is
  halved until it is granted, down to one slot, as a data stack's region is
  (`gs_reserve_region`), and N with it; `GS_SHARED_STATS` reports the budget
  obtained.
* **Slots.** A slot is fresh, live (a dynamic stack's, written by one
  thread), frozen (a region of an arena), or free (released, its pages still
  committed). A dynamic stack takes a free slot first, whose pages are warm,
  and a fresh one otherwise, whose usable part is then made read-write
  (`mprotect`; on Windows the vectored handler commits it on first touch, as
  it does a data stack).
* **The stack control block is the dynamic stack's, not the slot's.** It is
  part of the dynamic stack's descriptor, beside the header of `items`, and
  points into whichever slot the dynamic stack has at the time; `ds.items`
  is a resizable whose stack is that block. A push is the same bump, a
  `T[>..]&` to it is the same `gs_rref` as for any other array, and every
  function that grows an array through a reference grows a dynamic stack
  unchanged. Neither the header nor the block ever moves, so a `gs_rref`
  taken at any point stays good for the declaration's whole life, across
  every freeze, and none names a slot.
* **The limit.** A dynamic stack that finds all N slots live or frozen
  aborts, with a message giving B, R and N and the flag that raises B: the
  explicit limit option A asks for, reported, and not an `mmap` failure at
  an arbitrary point. With 16 TB beside the data stacks' 32 TB budget, the
  128 TB of user address space on x86-64 holds both.
* **Sizes.** R is the data stacks' reservation so that every check the
  compiler leaves out for data stacks it can leave out for dynamic stacks:
  a self-relative `u32` link needs no range check in a 2 GB reservation
  (§3.9). Growth past R reaches the slot's gap and ends the program with a
  message naming the dynamic stack, as a data stack's overrun does;
  `ds.items.check_length(n)` checks a count against R first, for a program
  that must not end there.
* **Faults.** The fault handlers find a slot from a faulting address with a
  subtraction and a division, and act on the slot's state: commit (Windows)
  in a live slot, report an overrun in a gap, report a write in a frozen
  slot that a debug build made read-only. Slots need no entry in a thread's
  region registry, and they take nothing from the regions a thread program
  counts, so `hardware_threads()` is unchanged.
* **Freezing** marks the slot frozen and records it in the arena with the
  array's byte length, takes a fresh slot (a free one where there is one),
  and points the dynamic stack's block and header at the fresh slot's start
  with a length of 0. That is the one change of a grow-only array's base in
  the language, and codegen treats it as a rebind of the array, reloading
  every cache of its base, length and top (section 9). In a debug build the
  frozen slot is made read-only first (4.9).
* **Frozen** slots belong to their arena, not to any thread. Each keeps its
  whole R; a program that freezes many small arrays packs them onto a few
  dynamic stacks (section 8.2), since a slot of the budget, not memory, is
  what a small frozen array costs.

A mapping's region is the system's mapping of the file, read-only and
shared: pages come from the page cache on first touch, with no commit
charge, and every thread sees one set of page tables.

### 5.3 Release and reuse

Releasing an arena releases its regions:

* **A frozen slot** goes to the budget's free list with its pages still
  committed. A new dynamic stack, on any thread, takes a free slot before a
  fresh one, so a program that builds and drops arenas repeatedly (a query
  per run, a join per batch) faults no new pages and makes no system call
  after the first round. Nobody can see a slot on the list: its arena had no
  attachment left.
* **A mapping** is unmapped (`munmap`, `UnmapViewOfFile`) by the thread
  whose detach released the arena. It is one call per file, about 15 ms per
  2 GB of mapped pages (11.1), made once.
* **The arena record** is freed.

No slot is unmapped while the program runs, which is option A's "keeping
the address reservation allows the runtime to guarantee reuse of its
budget". `trim_memory()` (`os`, §1.2) already gives a thread program's
unused stack pages back to the system; it also gives back the pages of
every free slot (`MADV_DONTNEED` on Linux, the `MAP_FIXED` replacement on
macOS, `MEM_DECOMMIT` on Windows), keeping the reservation. Option A
decommits a closed document's pages at once; this design leaves that to
`trim_memory()`, for a reason measured in 11.2: when 16 threads each
unmapped 64 MB of touched memory at the same moment, the release took
80 ms, against 4.8 ms for one thread alone, because the system serializes
it; `MADV_DONTNEED` took 30 ms; keeping the memory took nothing. Workers
that end together already unmap their data stacks that way today, and
frozen regions unmapped as stacks are would add to it.

An unfrozen dynamic stack's slot is released the same way, to the free
list, at the declaration's scope exit or after a contained abort. Its
contents were never visible to any other thread.

### 5.4 Stale and foreign handles

A **stale** handle names an arena that has been released, or a region of
one. It can still be copied, stored and sent, since it is a name.
Using it is a diagnostic: `attach` of it aborts, with a message saying that
the arena was released because no attachment was left, and the location.
Its regions can only be viewed through an attachment to its arena, which can
no longer be made, so no view of released memory exists.

A **foreign** handle names a region of another arena than the attachment's:
the view aborts, saying so. The zero handle names nothing: attaching or
viewing it aborts. Since a handle cannot be made from an integer, nor
returned by C (4.1), the runtime only ever sees handles it gave out, and
since arena serials are never reused (the 2^40-th arena aborts rather than
wrap), a stale handle can never come to name a new arena.

### 5.5 Mapping a file: errors, prefaulting, truncation

**Who maps.** Any thread can map. The intended use is that one thread
(main, typically) maps each file once and the others attach, because that
gives one mapping and one set of page tables for the process, one system
call per file, and, for a program that scans the same files repeatedly (a
benchmark's `--runs`, a server's queries), page tables that stay populated
from one run to the next. Workers mapping a file each would get the same
page cache but their own page tables, faulted again by every worker and
every run.

**Errors** are reported as section 4.5 says: `false` and a reason for
everything the system refuses at `map_file`, an abort for a view that does
not fit, and a successful mapping of size 0 for an empty file. A regular
file that the system will not map (a `/proc` file, a file system without
`mmap`) is read instead into memory the runtime maps for it, anonymous and
then made read-only, and released as a mapping is: the same handle, the
same views, a copy instead of a mapping. Section 7 uses the same fallback
where a platform has no `mmap` at all.

**Prefaulting and advice.** The runtime does neither by default, on the
evidence of section 11.1: on Linux's page cache, the first pass through a
fresh mapping ran at 16.4 GB/s on one thread and 143 GB/s on 16, against
20.4 and 158 GB/s once the page tables were populated, because the kernel
maps 16 cached pages per fault. `MAP_POPULATE` populated a 2 GB file in
55 ms on one thread, more than a whole first pass of 16 threads takes
(15 ms); `MADV_POPULATE_READ` per morsel slowed the scan to 13 and 84 GB/s;
`MADV_WILLNEED` made no difference with the file cached; and with the file
not cached every method ran at the volume's 0.14 GB/s. Advice has no
meaning a program can observe, so the runtime may add it for workloads that
show a gain (cold scans on fast devices, `MADV_SEQUENTIAL`), and an
explicit hint would be a later, optional member (section 17).

**Truncation.** A file truncated while mapped makes a read past its new end
raise SIGBUS (`BUS_ADRERR`, with the faulting address; 11.5). The runtime
cannot prevent it: Linux has no mandatory locks, file seals apply only to
memory files, and a private mapping faults the same way. Recovering is not
sound either: the fault can come from inside the runtime's own C
(`write_stdout` of a view copies it inside `fwrite`, holding stdout's
lock), which a jump out of the handler would leave held. So the choice is the one Goose makes for a data-stack
overrun: the fault handler, which already handles SIGBUS, finds the address
in the process's table of mappings, writes `goose runtime error:
<path> was truncated or could not be read while mapped: a read at byte
<offset> faulted`, and ends the process, in a contained worker as well
(§11.2 lists guard-page hits among what still ends the program). A write
fault inside a mapping is reported the same way, as a defect.

**Modification.** Another process that writes a mapped file's bytes in
place changes what views read. That is outside the guarantee, as it is for
every system that maps files: the program may read any mixture of old and
new bytes. Two things limit it. Views are of
plain data, so every byte pattern read is a value of its type (4.5); and
the generated code checks each index it loads before using it, so what the
compiler emits never reads outside a region because of a changed byte. What
it cannot promise is how a C compiler treats memory that changes under a
thread with no store of that thread's, which C's memory model does not
cover; hence "outside the guarantee". Writers that publish by writing a new
file and renaming it over the old one, as more-fast-db's `write_table` does,
never affect a mapping: the mapping holds the old file, which the system
keeps until it is unmapped. On Windows the runtime also denies other
processes write access while the file is mapped (section 7).

### 5.6 Threads, contained workers, aborts and `thread_wait`

* **Per-thread holds.** Each thread keeps its attachments and dynamic
  stacks on a stack of its own, in runtime memory: an attachment's
  declaration pushes its arena, a dynamic stack's pushes its slot (which a
  freeze replaces with the fresh one), and their scope exits pop them, in
  the reverse order scopes end in.
* **A contained worker's abort** (§11.2) jumps out of the worker's frames
  without running their exits. After the jump, `gs_run_contained`'s caller
  pops the whole stack, ending each attachment and returning each unfrozen
  slot to the free list, before it releases the worker's data stacks. The
  regions the worker froze are in their arenas and stay there: a
  partitioning worker that aborted after freezing two partitions leaves
  them for its peers. If one of its attachments was its arena's last, the
  arena is released at that point.
* **`thread_wait(id)`** returns once a worker has ended and "all of its
  Goose storage has been released" (§11.2); that now includes its
  attachments and dynamic stacks. So a thread that has waited for every worker
  knows that its own attachments are the only ones left.
* **A worker that returns** has ended every attachment by its scopes'
  exits; the stack is empty.
* **Ending the program** (`exit`, an abort outside a contained worker, a
  fault, `main` returning while workers run) releases nothing; the system
  reclaims the mappings and the budget with the process.
* **A worker may outlive its spawner**, as today; its attachments keep their
  arenas whether or not the spawner still has its own.

### 5.7 Ordering without atomics in the language

The regions are written by one thread and read by others, so the reads must
see the writes. They do, without any construct in the language:

* A region is complete before its handle exists: `freeze` returns the
  handle after the dynamic stack's last write, and `map_file` after the
  mapping is made.
* A handle reaches another thread only through a spawn argument, a queue
  message, a global copied at spawn, or a frozen region that itself arrived
  by one of these. Each orders what the sender did before the send ahead of
  what the receiver does after the receipt: a spawn by the thread's
  creation, a queue by its lock today and by the release and acquire any
  correct queue has (the faster queues of the messaging design keep it).
* The region tables are written under the arena's lock and read lock-free:
  an entry is published before any handle to it is made, and never changes
  or moves afterwards.
* The count is an atomic in the runtime, with acquire-release ordering, so
  the thread whose detach releases an arena sees every other thread's reads
  as finished.

The language keeps having no locks, atomics or memory orderings (reference
section 22); the runtime has them, as it has for queues and `thread_wait`.

## 6. Interaction with existing features

* **`thread_spawn` and `thread_spawn_contained`.** Handles are flat
  arguments; attachments, dynamic stacks and views are rejected as
  non-flat, with today's diagnostics. A worker's copies of main's globals may hold handles
  (flat globals are copied, §11.2); a root global attachment is not usable
  by a worker, which attaches its handle instead.
* **Contained workers and aborts**: section 5.6.
* **Queues.** Handles and values holding them are queue messages. A view
  is not, and neither is a struct holding one. A missed `qpoll` gives the
  zero handle.
* **Globals.** An attachment may be a global of the main program, where it
  is attached for the whole run and its views may be stored in globals.
* **Generics.** `resource<frozen<T>>`, `dynamic_stack<T>` and `view<T>` are
  instantiated per `T` like any generic type or builtin, and the freezable
  and plain-data checks run per instantiation, naming the instantiation
  chain, as other type rules do. A generic function over `T` that views
  `resource<frozen<T>>` handles is ordinary, and so is a binding's generic
  tag (`resource<Texture<f32>>`).
* **`checkfree` and bounds-check elimination.** A view is a slice whose
  length the analysis knows to be its `count` (a mapping view) or a fixed
  value (a frozen view); loops over it are check-free as loops over any
  slice are, which section 11.6 checks with today's compiler, including
  probing chains of self-relative links. A view's own checks do not count
  for `checkfree` (4.5). `freeze(ds)` kills what the analysis knew of the
  length of `ds.items`, and of every reference that may alias it, as a
  shrink through a call does.
* **Root structs.** A root struct may hold a reference to an attachment
  (`struct Ctx { sh: shared& }`, or a field of a worker's state), as it may
  hold a reference to any owner. Neither owner nests by value.
* **`defer`.** An attachment's or a dynamic stack's end is an exit action beside
  the restores and the `defer`s of its scope, in reverse declaration order
  (implementation.md §6.2), so a `defer` declared after the attachment can
  still use it. Unlike a `defer`, it also runs after a contained abort,
  because the runtime does it (5.6); [scope_exit_cleanup.md](scope_exit_cleanup.md)
  section 4.6's "what never runs them" does not apply to it.
* **Serialization.** `bytes_of` and `to_bytes` of a view work as on any
  slice (a frozen view of image-safe elements writes out as an image);
  `from_bytes` of a mapped view verifies and copies an image straight from
  the page cache (4.5). Handles are not image-safe.
* **`extern fn` and `export fn`.** A view passes to C as a `const T[:]`
  parameter, read-only, borrowed for the call, and a handle as a `uint64_t`
  (4.1). C still cannot return a slice, nor a handle of the runtime's kinds;
  a mapping comes from `map_file`.
* **Coroutines** ([coroutines.md](coroutines.md), designed, not built). A
  frame is flat when its fields are, and a handle is flat, so a frame
  holding handles can be queued to another worker (4.9 there). An
  attachment or a dynamic stack may not be in scope at a suspension point:
  that is rule R1, which names variable- and resizable-class locals,
  extended to these two owners for two reasons of their own. A frame is a
  plain value and cannot hold an owner, and a frame that is dropped would
  never end the attachment, which would keep its arena forever. Views rooted at an
  attachment *outside* the coroutine (an `sh: shared&` parameter, a global
  attachment) cross yields freely under R4, so the intended shape is the
  thread's event loop attaching once and its coroutines taking `sh: shared&`
  or holding handles and making views after each resume. A library `select`
  or channel over coroutines needs nothing more from this design than flat
  handles in its yield and resume values.
* **The messaging design** (addressed inboxes and `select`, designed
  alongside): handles go through inboxes and channels as any flat value
  does, and a `select` that wakes on a message delivers a handle like any
  other. Nothing here needs `select`; a program that waits for a frozen
  table waits for its handle's message.
* **Recursion.** An attachment has no components, so it may be live across
  a call into a recursive cycle; its hold is on a runtime stack that grows
  as needed. A dynamic stack may not (§7.8).
* **`trim_memory`** also returns the free slots' pages (5.3).

## 7. Platforms

| | Mapping a file | The dynamic stacks' budget | Truncation, I/O errors |
|---|---|---|---|
| Linux | `open(O_RDONLY \| O_CLOEXEC)`, `fstat`, `mmap(PROT_READ, MAP_SHARED)`, the descriptor closed at once | one `mmap(PROT_NONE, MAP_NORESERVE)` of the budget; a fresh slot's usable part made read-write with `mprotect` | SIGBUS in the existing handler |
| macOS | as Linux | as Linux; trimming replaces a free slot's pages with `MAP_FIXED`, as for stacks | as Linux |
| Windows | `CreateFileW(GENERIC_READ, FILE_SHARE_READ \| FILE_SHARE_DELETE)`, `CreateFileMappingW(PAGE_READONLY)`, `MapViewOfFile(FILE_MAP_READ)`; the file handle kept open while mapped | one `VirtualAlloc(MEM_RESERVE)` of the budget, committed on fault by the vectored handler, as data stacks are | `EXCEPTION_IN_PAGE_ERROR` in the vectored handler |
| wasm (design only, [wasm.md](wasm.md)) | the fallback: the file read into memory of its own | per wasm.md's partitions | none |

* **Windows** needs no deferral: the mapping calls are as direct as the
  POSIX ones, and the budget's slots reuse the data stacks' code paths. It
  is also stricter. A file with a mapped view cannot be truncated
  (`SetEndOfFile` fails with `ERROR_USER_MAPPED_FILE`), and the share mode
  without `FILE_SHARE_WRITE` keeps every other process from opening it for
  writing while it is mapped, which makes the immutability of 5.5 a
  guarantee there. `FILE_SHARE_DELETE` lets a writer rename a new file over
  it, as on POSIX. An empty file cannot be given a mapping object, so size 0
  is handled before `CreateFileMappingW`, as on POSIX before `mmap`.
* **The in-process TinyCC backend** compiles the same runtime C. A program
  without workers maps and freezes there as natively; a program with
  workers is refused by that backend already (spec Appendix E).
* **Big-endian hosts** abort at a view or a `map_file`, with the
  `GS_E_ENDIAN` that images use (serialization.md §3): mapped bytes are
  little-endian by the formats in use, every supported target is, and the
  test folds away there.

## 8. The uses, in Goose

### 8.1 Mapped column files

main maps each column file the scan reads, once, and freezes the
manifest's segment table (the metadata of 8.2), so that no worker parses
it. The workers attach the arena at their start and make each morsel's
vectors as views: no `pread`, no buffer, no copy. This is the source of
more-fast-db's `docs/source.md` with its I/O replaced; the dictionary
checks stay, since a file is input.

```goose
struct Mapped { file: resource<mapping>, ltype: LogicalType, column: i64 }

// What every worker needs, flat: the plan, the arena, the mapped columns of
// the scan, and the manifest's tables, frozen once by main.
struct Q1Args {
    plan: Plan,
    options: Options,
    arena: resource<shared>,
    cols: Mapped[..MAX_COLUMNS],
    segments: resource<frozen<Segment>>,   // row group g's segment of column k at g * columns + k
    group_rows: resource<frozen<i64>>,     // row group g's rows
    columns: i64,
}

fn fail(why: const u8[:]) { print_err(str("mfdb: error: ", why)); exit(1); }

fn main() {
    let opts = parse_options(args()[1..]);
    let plan = q1_plan();
    let sh = shared {};                    // main's attachment, for the whole run
    var table = source::Source { .. };     // main reads and checks the manifest, once
    guard source::open(table, plan, opts) else { fail(table.error); }
    var segs = dynamic_stack<Segment> {};
    segs.items.append(table.segments);
    var rows = dynamic_stack<i64> {};
    rows.items.append(table.group_rows);
    var args = Q1Args {
        plan: plan,
        options: opts,
        arena: sh.handle,
        cols: [],
        segments: sh.freeze(segs),
        group_rows: sh.freeze(rows),
        columns: table.columns.len,
    };
    for c in table.scan {
        let path = str(table.dir, "/", c.name, ".col");
        var why: u8[>..] = [];
        let m, ok = sh.map_file(path, why);
        guard ok else { fail(str("source: cannot map ", path, ": ", why)); }
        args.cols.push(Mapped { file: m, ltype: c.ltype, column: c.column });
    }
    let morsels = sched::table_morsels(0, source::row_group_count(table));
    source::close(table);
    let r = sched::run<agg::Partial>(morsels, args, opts.threads, q1_worker);
    sched::exit_on_failure(r);
    // ... combine the partials, finalize, ORDER BY, CSV, as today ...
}   // sh ends after run() waited for every worker: the files are unmapped here

root struct Q1State {
    sh: shared&,                           // the worker's attachment: every view's root
    args: Q1Args,
    dicts: StringDict[..MAX_COLUMNS] = [], // the morsel's dictionaries, views of the mapping
    // ... the operators' states, as today ...
}

thread_fn q1_worker(worker: i32, args: Q1Args) {
    let started = clock_ns();
    let sh = attach(args.arena);           // once per worker
    var state = Q1State { sh: sh, args: args, .. };
    init(state, args.plan, args.options);  // the operators' states, as today
    sched::worker_loop<agg::Partial>(worker, state, started, sched::MORSEL_WAIT_MS, q1_morsel, q1_finish);
}

// One morsel: its vectors are views of the mapped files.
fn q1_morsel(s: Q1State&, m: Morsel, report: WorkerReport<agg::Partial>&) {
    let segs = s.sh.view(s.args.segments);
    let rows = s.sh.view(s.args.group_rows)[m.row_group];
    var data: VectorData[..MAX_COLUMNS] = [];
    s.dicts.clear();
    for c in s.args.cols {
        let seg = segs[m.row_group * s.args.columns + c.column];
        match physical_type(c.ltype) {
            I32 => data.push(VectorData.I32 { v: view<i32>(s.sh, c.file, seg.offset, rows) }),
            I64 => data.push(VectorData.I64 { v: view<i64>(s.sh, c.file, seg.offset, rows) }),
            F64 => data.push(VectorData.F64 { v: view<f64>(s.sh, c.file, seg.offset, rows) }),
            Dict => {
                // codes, count, offsets, then the bytes (format.md, "dict")
                let codes = view<u32>(s.sh, c.file, seg.offset, rows);
                let count = view<u32>(s.sh, c.file, seg.offset + 4 * rows, 1)[0];
                let offs = view<u32>(s.sh, c.file, seg.offset + 4 * rows + 4, count + 1);
                let bytes = view<u8>(s.sh, c.file, seg.offset + 4 * (rows + count + 2), offs[count]);
                // the checks load makes today (docs/source.md), over the views
                guard source::valid_dictionary(codes, offs, bytes) else { abort("source: a corrupt dictionary"); }
                let id = m.row_group * s.args.columns + c.column;
                let d .= s.dicts.push(StringDict { offsets: offs, bytes: bytes, id: id });
                data.push(VectorData.Dict { codes: codes, dict: d });
            },
            _ => abort("source: Q1 reads no column of this type"),
        }
    }
    // The chunks of `data` go through the filter, the projection and the
    // aggregate as today. Nothing above read or copied a byte of the files.
    report.stats.morsels += 1;
}
```

Every view is rooted at the worker's attachment, which `Q1State` holds by
reference, and which outlives the state, the morsel loop and every chunk.
The names are more-fast-db's (`source::Source`, `sched::run`,
`physical_type`); `valid_dictionary` stands for today's dictionary checks,
made over views instead of a buffer. `StringDict`'s fields are already
`const` slots in more-fast-db, so a view is stored in them as a buffer's
view is today. The morsel's segments are 8-byte aligned by the format, so
the alignment checks pass, and a corrupt manifest that points elsewhere
aborts the worker with the file's name. Q1 at SF10 reads 2.64 GB in 7
files: with every worker viewing one mapping, the scan's input costs no copy
and no buffer, where today each of 16 workers holds 5.4 MB of buffers and
copies every byte once.

### 8.2 Read-only data from main: dictionaries, metadata, plans

**Plans** are flat and small (more-fast-db's `Plan` is a spawn argument
today); they stay copies. A large read-only structure is frozen instead.

**Metadata** is frozen as an array: 8.1 freezes the manifest's segment
table once, where today every worker reads and parses the manifest itself.

**Dictionaries** that main makes (decoding Parquet, or a global dictionary
for a column) are frozen per run rather than per morsel: all offsets in one
`u32` array, all bytes in one `u8` array, and a directory saying where
morsel `g`'s are. Three regions in all, whatever the number of morsels,
since each region holds a slot of the budget (5.2).

```goose
struct DictAt { offsets: i64, count: i64, bytes: i64 }   // morsel g's dictionary in the arrays
struct Dicts { at: resource<frozen<DictAt>>, offsets: resource<frozen<u32>>, bytes: resource<frozen<u8>> }

fn freeze_dicts(sh: shared&, row_groups: i64) -> Dicts {
    var at = dynamic_stack<DictAt> {};
    var offs = dynamic_stack<u32> {};
    var bytes = dynamic_stack<u8> {};
    for g in row_groups {
        at.items.push(DictAt { offsets: offs.items.len, count: 0, bytes: bytes.items.len });
        let n = decode_dictionary(g, offs.items, bytes.items);   // pushes n + 1 offsets from 0, and the bytes
        at.items[g].count = n;
    }
    return Dicts { at: sh.freeze(at), offsets: sh.freeze(offs), bytes: sh.freeze(bytes) };
}

// In a worker: morsel g's dictionary, as views. The result is rooted at the
// caller's attachment, which a reference parameter's pointee is.
fn dictionary(sh: shared&, d: Dicts, g: i64) -> StringDict {
    let a = sh.view(d.at)[g];
    let offs = sh.view(d.offsets)[a.offsets .. a.offsets + a.count + 1];
    let bytes = sh.view(d.bytes)[a.bytes .. a.bytes + offs[a.count]];
    return StringDict { offsets: offs, bytes: bytes, id: g };
}
```

The `Dicts` value is flat (three handles), so it goes into the workers'
arguments or into each `Morsel` message beside the row group.

### 8.3 A radix-partitioned hash join

Build and probe sides are column files of `i64` keys and payloads, mapped by
main. Phase 1 partitions with write-combining buffers (64 rows per
partition per worker, flushed whole), so each worker's output is one
array of rows and one array of runs, `(partition, start, count)`, instead of
P arrays: a dynamic stack is a declaration, and P is known only at run
time; option A's collection of dynamic stacks would give one per partition
(4.6, section 17). Phase 2 builds each partition's table as chain heads followed
by the rows, linked by self-relative references. Phase 3 views every table
cut to its heads. The barriers are main collecting each phase's results
before it puts the next phase's tasks. The three loops are the ones section
11.6 compiles as `checkfree` today.

```goose
import std;

struct Row { key: i64, payload: i64 }
struct Run { part: i64, start: i64, count: i64 }        // a run of one partition's rows
struct Entry { key: i64, payload: i64, next: Entry&<u32>? }

struct Side { keys: resource<mapping>, payloads: resource<mapping>, rows: i64 }
struct Job { arena: resource<shared>, build: Side, probe: Side, parts: i64 }

struct Morsel { start: i64, rows: i64 }                  // build side; rows < 0 stops phase 1
struct ProbeMorsel { start: i64, rows: i64 }             // probe side, a queue of its own
struct Partitioned { rows: resource<frozen<Row>>, runs: resource<frozen<Run>> }
struct Task { part: i64, inputs: resource<frozen<Partitioned>> }   // part < 0 stops phase 2
struct Built { part: i64, table: resource<frozen<Entry>>, heads: i64 }
struct Tables { built: resource<frozen<Built>> }         // phase 3's start, in partition order
struct Result { matches: i64, sum: i64 }

let MAX_PARTS = 1024;

// A multiplicative hash, kept non-negative so that `h % n` is an index.
checkfree inline fn mix(k: i64) -> i64 { ((k as! u64) * 0x9E3779B97F4A7C15 >> 1) as! i64 }

// Phase 1: one morsel's rows, from two views of the same rows, into the
// partitions' buffers; a full buffer is appended to the worker's rows as a run.
checkfree fn flush(buf: Row[..64]&, p: i64, rows: Row[>..]&, runs: Run[>..]&) {
    runs.push(Run { part: p, start: rows.len, count: buf.len });
    rows.append(buf);
    buf.clear();
}

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

fn build_table(sh: shared&, task: Task, t: Entry[>..]&) -> i64 {
    let inputs = sh.view(task.inputs);                   // one entry per worker
    var n = 0;
    for d in inputs { for r in sh.view(d.runs) { if r.part == task.part { n += r.count; } } }
    let heads = next_pow2(max(n, 1));
    for i in heads { t.push(Entry { key: 0, payload: 0, next: null }); }
    for d in inputs {
        let rows = sh.view(d.rows);
        for r in sh.view(d.runs) {
            if r.part == task.part { insert(t, heads, rows[r.start .. r.start + r.count]); }
        }
    }
    return heads;
}

// Phase 3: every probe key against its partition's frozen table. The links
// in a table's heads reach its rows past the cut.
checkfree fn probe(tables: const (const Entry[:])[:], keys: const i64[:], res: Result&) {
    for k in keys {
        let h = mix(k);
        let t = tables[h % tables.len];
        let b = h >> 7;
        var e = t[b % t.len].next;
        while e {
            if e.key == k { res.matches += 1; res.sum += e.payload; }
            e .= e.next;
        }
    }
}

thread_fn join_worker(job: Job) {
    let sh = attach(job.arena);                          // one attachment for all three phases

    // Phase 1: partition the build morsels this worker takes.
    var rows = dynamic_stack<Row> {};
    var runs = dynamic_stack<Run> {};
    var bufs: Row[..64][>..] = [];
    for p in job.parts { bufs.push([]); }
    loop {
        let m = qget<Morsel>();
        guard m.rows >= 0 else { break; }
        scatter(view<i64>(sh, job.build.keys, m.start * 8, m.rows),
                view<i64>(sh, job.build.payloads, m.start * 8, m.rows), bufs, rows.items, runs.items);
    }
    for p in bufs.len { if bufs[p].len > 0 { flush(bufs[p], p, rows.items, runs.items); } }
    qput(Partitioned { rows: sh.freeze(rows), runs: sh.freeze(runs) });

    // Phase 2: whole partitions' tables, as many as this worker takes.
    var t = dynamic_stack<Entry> {};
    loop {
        let task = qget<Task>();
        guard task.part >= 0 else { break; }
        let heads = build_table(sh, task, t.items);
        qput(Built { part: task.part, table: sh.freeze(t), heads: heads });   // t is empty again
    }

    // Phase 3: probe every table.
    let built = sh.view(qget<Tables>().built);
    var tables: (const Entry[:])[..MAX_PARTS] = [];
    for b in built { tables.push(sh.view(b.table)[..b.heads]); }
    var res = Result { matches: 0, sum: 0 };
    loop {
        let m = qget<ProbeMorsel>();
        guard m.rows >= 0 else { break; }
        probe(tables, view<i64>(sh, job.probe.keys, m.start * 8, m.rows), res);
    }
    qput(res);
}

fn map_column(sh: shared&, path: const u8[:]) -> resource<mapping> {
    var why: u8[>..] = [];
    let m, ok = sh.map_file(path, why);
    guard ok else { abort(str("join: cannot map ", path, ": ", why)); }
    return m;
}

fn map_side(sh: shared&, dir: const u8[:]) -> Side {
    let keys = map_column(sh, str(dir, "/key.col"));
    let pays = map_column(sh, str(dir, "/payload.col"));
    assert(sh.size(keys) == sh.size(pays) && sh.size(keys) % 8 == 0);
    return Side { keys: keys, payloads: pays, rows: sh.size(keys) / 8 };
}

fn main() {
    let workers = hardware_threads();
    let parts = min(4 * workers, MAX_PARTS);
    let sh = shared {};
    let job = Job { arena: sh.handle, build: map_side(sh, "build"), probe: map_side(sh, "probe"), parts: parts };
    var start = 0;
    while start < job.build.rows {
        let n = min(122880, job.build.rows - start);
        qput(Morsel { start: start, rows: n });
        start += n;
    }
    for w in workers { qput(Morsel { start: 0, rows: -1 }); }
    var ids: i64[>..] = [];
    for w in workers { ids.push(thread_spawn_contained(join_worker, job)); }

    // Barrier 1: every worker's partitions are frozen.
    var inputs = dynamic_stack<Partitioned> {};
    for w in workers { inputs.items.push(qget<Partitioned>()); }
    let dir = sh.freeze(inputs);
    for p in parts { qput(Task { part: p, inputs: dir }); }
    for w in workers { qput(Task { part: -1, inputs: dir }); }

    // Barrier 2: every partition's table is frozen. In partition order.
    var built = dynamic_stack<Built> {};
    for p in parts { built.items.push(Built { part: p, table: default<resource<frozen<Entry>>>(), heads: 0 }); }
    for p in parts { let b = qget<Built>(); built.items[b.part] = b; }
    let tables = sh.freeze(built);
    for w in workers { qput(Tables { built: tables }); }
    start = 0;
    while start < job.probe.rows {
        let n = min(122880, job.probe.rows - start);
        qput(ProbeMorsel { start: start, rows: n });
        start += n;
    }
    for w in workers { qput(ProbeMorsel { start: 0, rows: -1 }); }

    var total = Result { matches: 0, sum: 0 };
    for w in workers { let r = qget<Result>(); total.matches += r.matches; total.sum += r.sum; }
    var why: u8[>..] = [];
    for id in ids { if !thread_wait(id, why) { abort(str("join: a worker aborted: ", why)); } }
    print(total.matches, " matches, payloads summing to ", total.sum);
}   // sh ends: the last attachment. The files are unmapped and every region recycled.
```

What the example shows about the fit:

* **Who owns what.** Main's attachment is the arena's lifetime; each
  worker's covers its three phases. The partitions, the tables and the
  directories are all in one arena, so nothing is released while any worker
  might still attach or view it, with no protocol beyond the barriers the
  join has anyway. A program that wanted the partitions' memory back before
  phase 3 would freeze them into a second arena and end the workers'
  attachments to it after phase 2.
* **Copies.** None of the build side's rows is copied between threads: each
  is written once into a partition, once into a table, and read in place by
  every prober. Against private copies of the tables (the alternative of
  2.3), 16 workers save 15 copies of the tables' memory and the time to
  make them.
* **Checks.** The loops over views are `checkfree`. `assert(pays.len ==
  keys.len)` states once what makes `pays[i]` safe; `mix(k) % n` is an
  index of an array of length `n`; following `.next` is unchecked. The
  remaining checks (the view checks, `rows[r.start .. r.start + r.count]`,
  `tables.push` against `MAX_PARTS`) are per morsel or per run, not per row.
* **Aborts.** A contained worker that aborts in any phase releases its
  attachment and its unfrozen dynamic stacks (5.6). This main would then
  wait for that worker's message forever; a real one takes each phase's
  results with a timed `qget<T>(ms)`, or with the messaging design's
  `select` on the queue and the worker's end, and fails the query with the
  worker's message. The arena is released when main ends its attachment.

## 9. The generated C

Representative C for the forms above, at the level of detail of
implementation.md §6. Names follow the existing conventions: `_g` program
names, `gs_` runtime names, and a check's file and line passed as
`gs_file0, n`.

```c
/* Representation (runtime.h, after gs_rref). */
typedef uint64_t gs_res GS_ALIGN1;          /* resource<U>, every kind: one u64; 0 is no resource */
#define GS_RES_SERIAL_BITS 40               /* the runtime's kinds: the arena's serial, high bits */
#define GS_RES_REGION_BITS 24               /* and the region's number in it, low bits */
_Static_assert(GS_RES_SERIAL_BITS + GS_RES_REGION_BITS == 64, "a handle is one u64");
typedef struct gs_arena gs_arena;           /* runtime-private */
typedef struct gs_slot gs_slot;             /* a slot of the dynamic stacks' budget: memory and a state */
typedef struct { gs_arena *a; } gs_att;     /* a shared attachment, in its frame */
typedef struct {                            /* a dynamic_stack<T>, in its frame */
    gs_slot *slot;                          /* the slot it has now; freeze replaces it */
    gs_stack stack;                         /* its own stack block, pointing into that slot */
    gs_rhdr items;                          /* the header of items: base, len */
} gs_dstack;

/* let sh = shared {};   ...   and on every exit of its scope: */
gs_att sh_g;
gs_shm_new(&sh_g);
...
gs_shm_detach(&sh_g);

/* let sh = attach(job.arena); */
gs_att sh_g;
gs_shm_attach(&sh_g, job_g.arena_g, gs_file0, 12);  /* aborts on a zero or released arena */

/* let m, ok = sh.map_file(path, why); */
gs_res m_g;
uint8_t ok_g = gs_shm_map_file(&sh_g, path_g, &m_g, why_g, gs_file0, 13);

/* let xs = view<i64>(sh, m, off, n);  gs_shm_view is inline: the serial
   compared, the region's record loaded, three compares and an and. */
sl_i64 xs_g;
xs_g.data = (gs_i64 *)gs_shm_view(&sh_g, m_g, off_g, n_g, 8, 8, gs_file0, 14);
xs_g.len = n_g;
for (int64_t t9 = 0; t9 < (xs_g.len); t9++) {      /* today's loop over a slice */
    x_g = xs_g.data[t9];
    s_g = gs_add_i64(s_g, x_g, gs_file0, 15);
}

/* var ds = dynamic_stack<Row> {};  on every exit of its scope, gs_dstack_close(&ds_g).
   ds.items is a resizable whose stack is ds_g.stack: a push is today's push,
   and a Row[>..]& to it is gs_rref { &ds_g.items, &ds_g.stack }, which no
   freeze changes. */
gs_dstack ds_g;
gs_dstack_open(&ds_g, gs_file0, 16);                 /* aborts when every slot is in use */
uint8_t *t3 = ds_g.stack.top;                        /* the top, cached as for any stack */
*(Row_g *)t3 = row_g; t3 += 16; ds_g.items.len++;
ds_g.stack.top = t3;                                 /* written back before a call that grows it */
fill_g(&ds_g.items, &ds_g.stack);                    /* fn fill(out: Row[>..]&) */
t3 = ds_g.stack.top;                                 /* and reloaded after it */

/* let r = sh.freeze(ds);  cached tops are written back first. Afterwards
   ds_g.items.base and ds_g.stack.top point at a fresh slot, len 0, so every
   cached base, length or top of ds.items is reloaded, here and in each
   caller that holds a reference to it, as after a rebind. */
ds_g.stack.top = t3;
gs_res r_g = gs_shm_freeze(&sh_g, &ds_g, 16, gs_file0, 18);
t3 = ds_g.stack.top;                                 /* the fresh slot's start */

/* let rows = sh.view(r);  and following a link, e .= e.next, as today */
sl_Entry rows_g;
rows_g.data = (Entry_g *)gs_shm_frozen(&sh_g, r_g, 24, &rows_g.len, gs_file0, 19);
...
int64_t t29 = (int64_t)(gs_i32)(*e_g).next_g;
e_g = (Entry_g *)(t29 ? ((uint8_t *)&(*e_g).next_g) + t29 : NULL);
```

* `gs_res` is one `uint64_t`, for every kind, as option C has it. For the
  runtime's kinds of this design its high 40 bits are the arena's serial and
  its low 24 the region's number, 0 for the arena itself (4.1). A handle is
  copied and packed as the eight bytes it is; nothing compares it. An
  `extern fn` passes it as `uint64_t`.
* An attachment is one pointer in its frame. `shared&` parameters pass a
  `gs_att *`. A dynamic stack in a frame is its slot pointer, its own stack
  block and its component's header. A `dynamic_stack<T>&` parameter is
  passed field by field, as a root parameter is (`FindSplitRootParams`,
  implementation.md and root_structs.md), and `ds.items` as `T[>..]&` is
  `{ &items, &stack }`, which never changes. A parameter that is frozen is
  handed to a builtin, so it keeps the descriptor's address, by that
  function's existing rule, and the freeze updates the caller's descriptor.
* **A freeze rebases `ds.items`**, the only operation that changes a
  grow-only array's base, and codegen treats it as a rebind of the array
  for every cache it keeps. In the freezing function, no cached base,
  length or top of `ds.items` is carried across the freeze, and a loop that
  may freeze it hoists none of them (`hoistrefs`, `hoistfields`). A
  specialization that may freeze, itself or through a call, records in its
  effect summary the dynamic stack components it may rebase, and a call to
  it reloads, in the caller, the caches of every reference that may reach
  one, as calls already write back and reload the stack tops their callees
  may move (`SyncReach`). Without this, a base cached before the freeze
  would read and write the frozen slot.
* The scope exits are emitted by `EmitExitRestores`, as entries of the
  scope beside the stack restores and `defer`s, in reverse declaration
  order, so every exit path (`break`, `continue`, `return`, `return …
  from`'s propagation) runs them.
* A view's C is an ordinary slice, so the hot loop is today's loop over a
  slice (the `for` above is what `-O2` emits for a loop over a `const i64[:]`
  parameter now), and the C compiler vectorizes it as it does now.

The runtime's entry points, declared in `runtime.h` and defined in a new
`runtime_shared.h` after `runtime_threads.h`:

| Function | Does |
|---|---|
| `gs_shm_new(gs_att *)` | a new arena, attached once, registered by its serial; aborts when serials are used up |
| `gs_shm_attach(gs_att *, gs_res, loc)` | look the serial up under the registry's lock; increment, or abort (`GS_E_STALE`, `GS_E_NOHANDLE`) |
| `gs_shm_detach(gs_att *)` | decrement; at zero, unregister and release (5.3); pops the thread's hold |
| `gs_shm_map_file(gs_att *, sl_u8, gs_res *, gs_rref why, loc)` | 4.5 and 5.5; registers the mapping for the fault handlers |
| `gs_shm_size(gs_att *, gs_res, loc)` | a mapping's size |
| `gs_shm_view(...)` (inline) | the checks of 4.5 (`GS_E_FOREIGN`, `GS_E_VIEW`); the address |
| `gs_dstack_open(gs_dstack *, loc)`, `gs_dstack_close(gs_dstack *)` | take a slot of the budget, reserving the budget on first use, or abort (`GS_E_BUDGET`); give it back; push or pop the hold |
| `gs_shm_freeze(gs_att *, gs_dstack *, elemsize, loc)` | 4.6 and 5.2; the new region's handle |
| `gs_shm_frozen(gs_att *, gs_res, elemsize, int64_t *len, loc)` (inline) | a frozen view's address and length |
| `gs_shm_release_held(void)` | after a contained abort: end every attachment and dynamic stack of the thread (5.6) |

## 10. What changes in the compiler and the runtime

By pass, with the existing code each change extends. Step 0, `resource<U>`
on its own:

* **Resolution** (`resolve.h`). `resource<U>` resolves, where no
  declaration of the program has the name, to a new `TypeKind`,
  `TY_RESOURCE`, whose `sub` is the kind: any type, with `shared`, `mapping`
  and `frozen<T>` (and the messaging design's `event`) marked as the
  runtime's.
* **Types** (`typecheck_types.h`). `IsFlat`: a handle is flat. `ImageSafe`:
  a handle is not ("a handle names something only its binding can read").
  Defaults: all bits zero. Conversions (`as`, `as!`) to and from a handle
  are rejected, and so are the comparisons, where `==` already refuses a
  function value (`typecheck_exprs.h`), including the structural `==` of a
  type holding a handle. Printing renders the type's name alone
  (`codegen_render.h`).
* **The C boundary** (`ExternValueOk`, `ExternParamOk`,
  `typecheck_calls.h`). A handle crosses by value as `uint64_t`; a result,
  or a value returned that holds one, may not be of the runtime's kinds.
* **Codegen.** `CT` of a handle is `gs_res`, a `uint64_t`, for every kind.

Phases 1 and 2:

* **Owner types.** `shared` and `dynamic_stack<T>` resolve to builtin
  struct declarations with the existing `isroot` mark and a builtin-owner
  kind, so that every placement, copy and transfer rule of root structs
  applies to them unchanged. `shared {}`, `attach(h)` and
  `dynamic_stack<T> {}` are accepted only as the initializer of an owning
  declaration, as root struct literals are; anywhere else, the root-owner
  diagnostic. `dynamic_stack<T>` takes a fixed-size `T`.
* **Type predicates** (`typecheck_types.h`). New `PlainData(t, why)` (4.5)
  and `Freezable(t, why)` (4.7, built from `HoldsPlainRef`, `HoldsIndexT`
  and the `in pool` test of `ImageSafe`).
* **Builtins** (`builtins.h`, `typecheck_builtins.h`). New entries in the
  `BUILTINS` table: `attach`, and `handle` (`BF_PROPERTY`), `map_file`,
  `size`, `view` (`BF_TYARGS`, optional) and `freeze`, whose receiver is an
  attachment (a receiver kind beside the array kinds of `BuiltinRecv`), with
  their checks in `CheckBuiltin`. A view's `Val` is the receiver's roots and
  exactness (as `push`'s reference result is, `RootedAtReceiver`), not
  writable, its type `const T[:]`. `freeze` runs the checks of a shrink of
  `ds.items` (`CheckGrowShrink`, `BF_SHRINKS` on the component) and logs it
  in the specialization's shrink summary, so callers are checked too, and
  checks `Freezable` for `T`.
* **Read-back** (`RootCandidates`, `HoldsByValue`): an attachment holds by
  value every plain-data and freezable type (4.4), as `StaticCanContain`
  makes static data hold literal-suppliable types.
* **Coroutines**, when they are built: R1's check (`CycleCallTemps`'s reuse
  at a yield) includes the two owners.
* **Bounds-check elimination** (`bce.h`). A mapping view's length is its
  `count` argument; a frozen view's is unknown and fixed; `freeze` kills
  the length facts of `ds.items` and of every reference that may alias it,
  as a shrink through a call does. A view's checks are not kept
  checks for `checkfree` (`Call::nobc` is not involved; they are aborts of
  their own).
* **Codegen.** `codegen_types.h`: `CT` of the owners, `gs_att` and
  `gs_dstack`. `codegen_builtins.h`: emitting each builtin as section 9
  shows. Scope exits: the two owners' end actions as scope entries
  (`EmitExitRestores`, `RegisterDefer`'s neighbor). `codegen_frames.h`:
  `shared&` as one pointer, `dynamic_stack<T>&` split as root parameters
  are. Stack-top caching and view hoisting (implementation.md §6.10): a
  dynamic stack's stack is its descriptor's own block, reached as a fat
  reference's is; `freeze` rebases `ds.items`, so the caches treat it as a
  rebind (section 9): nothing cached is carried across it, and the
  dynamic stack components a specialization may rebase join its effect
  summary, so that its callers reload what they cached of references that
  may reach them.
* **Driver.** `--dynamic-budget size` writes `-DGS_DYNAMIC_BUDGET`, as
  `--stack-reserve` writes `GS_STACK_RESERVE`.
* **Runtime.** `runtime_shared.h` (new): the arena registry and records,
  attach and detach, the per-thread hold stack, the dynamic stacks' budget
  with its slots and free list, mapping on POSIX and Windows, the fallback
  copy, views, freeze, `GS_SHARED_STATS` reporting at exit for tests.
  `runtime_impl.h`: the fault handlers (`gs_fault_handler`,
  `gs_fault_filter`) look up the process's mappings for SIGBUS,
  `EXCEPTION_IN_PAGE_ERROR` and write faults, and the budget's slots for
  commits and overruns; `gs_trim_memory` trims the free slots.
  `runtime_threads.h`: `gs_thread_main` calls `gs_shm_release_held()` after
  a contained abort, before `t->release()`. `runtime_inline.h` is
  regenerated (`--gen-runtime-header`).
* **Language server.** Hover, completion and signature help for the
  builtins on a `shared` receiver come from the builtin table, as for the
  array members.
* **Nothing else.** No lexer or parser change, no formatter change, no new
  keyword for editors to highlight.

## 11. Measurements

Linux 7.0 on aarch64 (Neoverse N1, 16 cores, 64 GB, 4 KB pages), clang
-O2, the file on the overlay file system the more-fast-db data lives on,
warm in the page cache unless stated. Medians of three runs. The programs
are in `bench/shared_memory/`, and its README has the commands.

### 11.1 Scanning a file: copies against a mapping

Summing a 2 GB file of 2^28 `i64`s, in morsels of 983,040 bytes (one
more-fast-db row group of an `i64` column) that the threads take from an
atomic counter, as they would from the morsel queue (`mapbench`):

| Method | 1 thread | 16 threads |
|---|---:|---:|
| `pread` into a reused buffer per thread | 9.5 GB/s | 73 GB/s |
| the whole file read into memory first (`read_file`'s shape, 0.86 s), then summed | 2.2 GB/s | 2.5 GB/s |
| a shared read-only mapping, first pass (page faults) | 16.4 GB/s | 143 GB/s |
| the same mapping, later passes | 20.4 GB/s | 158 GB/s |
| `MAP_POPULATE`, including its 55 ms | 13.1 GB/s | 30 GB/s |
| `MADV_POPULATE_READ` per morsel | 13.1 GB/s | 84 GB/s |
| `MADV_WILLNEED` per morsel | 15.5 GB/s | 135 GB/s |
| `pread`, mapping, `MADV_WILLNEED` or `MADV_POPULATE_READ`, the file's pages dropped first (`POSIX_FADV_DONTNEED`) | 0.14 GB/s | 0.14 GB/s |

Unmapping the 2 GB mapping after a pass took 15 ms. A fault maps 16 cached
pages at once (the kernel's fault-around), which is why the first pass
costs so little; a copy moves every byte twice. The cold rows are one run
each, and are bound by the volume.

### 11.2 Releasing memory when threads end together

Each thread reserves 2 GB regions like a data stack, touches 64 MB, and all
release at the same moment (`release`):

| Release | 16 threads at once | 1 thread |
|---|---:|---:|
| `munmap` | 80 ms | 4.8 ms |
| `madvise(MADV_DONTNEED)` | 30 ms | 4.7 ms |
| kept for reuse | 0.03 ms | 0.00 ms |

Four 16 MB regions per thread instead of one 64 MB region give the same
times (82 and 29 ms). Releases serialize in the kernel, so the cost grows
with the number of threads releasing at once, not with the memory per
thread.

### 11.3 Making a region read-only

`mprotect(PROT_READ)` of a region whose pages are all written (`mprot`):
48 µs for 4 MB and 1.1 ms for 64 MB with no other thread running; 53 µs
and 1.4 ms with 15 threads running, which the system must make drop their
cached translations. So it is a debug-build check (4.9).

### 11.4 The attachment count

An attach and a detach, as an atomic increment and decrement of one
counter that every thread uses (`attach`): 11 ns per pair on one thread,
148 ns on four, 1.0 µs on 16. Once per worker or per phase it is nothing;
per morsel (milliseconds of work) it is under 0.1%; per chunk or per view it
would show, which is why views do not count (5.1).

### 11.5 Truncation

A file mapped `PROT_READ, MAP_SHARED`, truncated through another descriptor
(as another process would), then read past its new end (`sigbus`): the read
raises SIGBUS with `si_code` `BUS_ADRERR` and the faulting address, from
which the handler finds the mapping and the offset (here 8192). Reads
inside the new size succeed.

### 11.6 `checkfree` over views

A view is a `const` slice, so whether loops over views are check-free can
be tested now, with `const` slices standing in for views.
`bench/shared_memory/join_loops.goose` holds the three loops of section 8.3
(scattering two views of one morsel, building chains of self-relative links,
probing them through tables cut to their heads) as `checkfree` functions. It
compiles with today's compiler at `-O0`, `-O1` and `-O2`, and matches a
reference sum. One gap turned up: the analysis proves `xs[h % xs.len]` for
a hash bound to a local, `let h = mix(k);`, and also for `(k * 31) %
xs.len` written in place, but not for `xs[mix(k) % xs.len]` with the
inlined call in place at `-O1` and above. The example binds the hash first;
the gap belongs with TODO 0f.

## 12. Alternatives considered

**Views rooted at the handle.** The handle is a flat value: its copies are
in other variables, structs, queues and threads, and a copy is a `memcpy`.
A root has to be one variable with one scope, so the handle cannot be it
without counting copies (below). The attachment is the variable.

**Counting handles, or views** (`Arc`, `shared_ptr`). Every copy of a flat
value would need an atomic, including the copies the language makes by
`memcpy` (a struct holding a handle, a queue image, a spawn packet), and a
destructor at every overwrite and every scope exit of a value holding one:
scope_exit_cleanup.md's "destructor types", rejected there for exactly this
cost. Counting views would put an atomic in every view (11.4: 1.0 µs under
contention) and still need the destructors. Counting attachments counts
declarations, which already have scope exits.

**Attaching each region rather than the arena.** This was the first form
considered. Phase 3 of the join needs all P tables at once, which is P
attachments in one scope, which needs an array of owners (root_structs.md
lists small constant arrays of owners as a v2 candidate; a run-time P needs
more than that), or P atomics per worker. And the release of a table would
then hang on its maker's attachment: a worker that finished its probes
early would release its table while slower workers had not yet attached it.
The arena moves both to one decision in one place.

**A handle of two words, with `==`.** This note first proposed a 16-byte
`resource<U>`, a 64-bit serial and a 64-bit region number, so that no
serial could ever be used up, and allowed `==` on handles. Option C's one
`u64` holds a 40-bit serial and a 24-bit region number with room no program
reaches (4.1), keeps handles half the size in every message and coroutine
frame that carries them, and is what the messaging design's events use too.
Nothing in this design compares handles. Both were dropped for option C as
it stands.

**A builder type of its own.** This note first called the frozen array's
owner `builder<T>`. Goose already calls a `T[>..]` a builder (the README's
"`u8[>..]` is a builder", §7.10's builders), and what is new here is the
memory under the array, a stack made at run time, which §11.3 and option A
already plan. Presenting it as their first step, `dynamic_stack<T>`, keeps
one concept: option A's collection generalizes it later instead of sitting
beside a different idea (4.6).

**Structured lifetimes: the owner waits.** The arena's creator could block
at its scope's end until every attachment has ended, so that lifetimes nest
like scopes and no count is needed. A worker attached to the arena that
waits for a message from the creator would then deadlock with it, and the
runtime cannot see that coming. The deferred release of 5.1 never blocks.

**Static proof through `thread_wait`.** "An arena lives in main's scope, and
main waits for every thread that has its handle" would make the release
point static, but handles are flat and travel through global queues, so the
compiler cannot know which threads have one. It is what the count gives at
run time, in the programs that have that shape (5.1).

**Epochs** (RCU). Threads announce quiescent points; memory retired in an
epoch is freed once every thread has passed one. It needs every thread to
keep announcing, a blocked thread stalls all reclamation, and views would
have to be tied to the time between quiescent points, which is a lifetime
the checker cannot express. An attachment is a scoped critical section with
an explicit end; it is the part of epochs Goose needs.

**Owner release with "no new attaches".** A separate owner whose end
forbids new attachments even while others hold the arena would make release
independent of who still reads. It turns the protocol question (has the
receiver attached yet?) into one more way to see a stale handle, without
removing any. The count alone has one rule.

**Freezing ordinary arrays.** A `T[>..]` on a data stack shares its stack
with other values, in LIFO order, and its pages are the thread's. Freezing
it would copy it (losing zero copy, and the O(1) handover for large builds)
or remap its pages (`mremap` is Linux-only and needs page alignment the
array does not have). Inferring which arrays are frozen and giving them
stacks of their own would change an array's representation by what a
distant call does with it. A dynamic stack says it at the declaration.

**Frozen data on the freezing thread's data stacks, kept alive with that
thread.**
Every reader would read another thread's stack, which that thread releases
at exit, and which is LIFO: one frozen array could not be released in the
middle. Workers could not end before their readers.

**Verified views of mapped files** (`from_bytes`'s verifier, run once over
the range, then a view of enums, bools and links in place). A file another
process writes could change a tag or a link after it was verified, and a
link pointing outside the region would read arbitrary memory. Plain data
cannot be made invalid by any write. Verified views of *frozen* bytes,
which nothing can change, remain possible (section 17).

**Mutable shared memory with locks or atomics in the language.** Ruled out
by the brief: race freedom stays a property the compiler proves.

**`extern fn` returning views, with an annotation or `unsafe`.** Goose has
neither lifetime annotations nor `unsafe`, and adding either for this would
leave the guarantee to the binding's author.

**Each worker mapping the file.** Not measured. On one pass it should cost
what one mapping costs, since the page cache is shared and each worker
faults only the pages it reads; on repeated passes it is worse, since each
worker's page tables are faulted again every run, and it makes W mappings
per file. A worker may still map a file only it reads.

**Status quo: copies.** `pread` per worker costs a copy and a buffer per
worker (11.1: 1.7x to 2.2x slower than a mapping); private copies of shared
tables cost W times the memory and the time to make them (2.3).

**Shared const globals** (a global main fills before its first spawn, then
shared instead of copied). Appealing for main-to-worker data, but it needs a
proof that main does not write the global after the first spawn, which is
flow-sensitive across main's whole program, and it gives no way to share
what a worker built. A frozen region covers both.

## 13. Consistency with the specification and the other notes

### 13.1 The deviations that remain

Two, and an upstream review should look at them first. Each departs from a
sentence of the specification for one reason, the same for both: the
scopes that see shared memory are in different threads, so no one thread's
scope can own it, and no one scope's exit can be the moment it is freed.

1. **A third kind of memory.** §1.2: "There is no general-purpose heap and
   no `malloc`. All dynamic allocation is expressed as values living on data
   stacks, owned by locals (or globals)." Mapped files and frozen regions
   live outside every thread's data stacks, in memory that several threads'
   scopes see at once; a thread's own stacks are released when it ends
   (§11.2), so they cannot hold what outlives the thread. The deviation is
   kept to what sharing needs. A live dynamic stack is a data stack in
   §1.2's sense, made at run time as §11.3 plans and owned by its
   declaration; what has no owning declaration is a *frozen* dynamic stack
   and a mapping, and both are owned by an arena, whose life is its
   attachments' scopes. Nothing is a heap: nothing is allocated object by
   object or freed one by one, and the memory never moves. §1.2 gains
   *shared regions* as a third kind of memory for values, beside the data
   stacks and static data (the native stack holds only a frame's fixed-size
   values), and points to §11.4.
2. **The runtime counts attachments.** §4.1: "There is no ownership transfer
   beyond the return move, no destructors, no `Drop`, no reference
   counting. The only deallocation is scope exit resetting stack
   pointers." An arena is released when its last attachment ends, and the
   runtime counts attachments to know when that is. The compiler cannot
   know it: handles are flat and travel through global queues, so which
   threads will attach is known only at run time (section 12 weighs the
   static alternatives). The deviation is kept small. No value is counted;
   the count changes only at an attaching declaration and at its scope's
   exits, beside the stack restores, never when a handle or a view is
   copied; nothing runs a destructor; and a program whose main attaches,
   spawns and waits gets a release point it can name (5.1). §4.1 says "no
   reference counting of values" and points to §11.4. The README's "no
   reference counting" stays true of values.

### 13.2 What the design adopts as proposed

* **owning_dynamic_data.md, option C.** `resource<U>` as option C states
  it: one `u64`; stored, copied and passed to the APIs of its kind, and
  never dereferenced, computed with, compared or converted; kinds that
  bindings define, the runtime being the binding of its own (4.1).
  Being a fixed-size value gives a handle a zero default, a text form that
  is its type alone, and no image, and none of these lets code compute with
  a handle or make one. Option C's open question, cleanup, stays open for
  the kinds bindings define; the runtime's kinds of this design need none,
  since a handle owns nothing. Option C's "direct mapped views would need a
  separate design connecting their bounds and lifetime to the resource" is
  this design.
* **§11.3 and option A.** `dynamic_stack<T>` is their first step, one
  stack, with option A's stable data, independent release and budgeted
  reservation (4.6, 5.2, 5.3); option A's recoverable limit errors wait for
  its collection (section 17), which generalizes `dynamic_stack<T>`.
* **coroutines.md.** R1 is extended to the two new owners, which a frame,
  a plain value, cannot hold, and which a dropped frame would never end; R4
  lets views rooted outside a coroutine cross yields; frames holding handles
  are flat and cross queues, as its 4.9 wants; its libraries' `select` and
  channels need nothing else.
* **root_structs.md.** The two owners follow every root rule unchanged.
* **relative_references.md.** Self-relative references work in frozen
  regions because they are position-independent and stay in their array;
  `in pool` references do not, because each thread has its own pool.
* **serialization.md.** Mapped bytes of plain data need no verifier because
  there is nothing to verify; anything else from a file still goes through
  `from_bytes`. `bytes_of` views stay unwritable for the reason frozen
  regions do.
* **string_constants.md.** Views are `const`, and the slots that hold them
  say so, as for static data.
* **scope_exit_cleanup.md**, "do not add destructor types now". The owners
  are not destructor types: they live only at declarations, are never
  copied, stored or removed from a container, and their end action is the
  runtime's, like a stack restore. Its section 4.6, on what never runs an
  exit action, does not hold for them, since the runtime releases them after
  a contained abort.

### 13.3 Additions that contradict nothing

The specification grows in places without any rule of it changing: §1.1's
root class gains the two builtin owners; §3.12 (new) is `resource<U>`; §5.1
gains `freeze` among the shrinks of a grow-only array, the one that also
starts the array again on new memory, which no live view of the old
elements can see and every reference to the whole array follows; §7.10
gains `resource<U>` as a shape that crosses, as `uint64_t`; §9.3 gains the
new aborts; §10.4 gains the dynamic stacks' budget beside the data stacks';
§11.2's list of what ends the program in a contained worker gains a
truncated mapping and a dynamic stack's overrun, beside guard-page hits;
§11.3 gains its first step; and §11.4 (new) is this design's rules.

## 14. Test plan

Following docs/testing.md. Positive fixtures go in a new category,
`test/shared/`, with `expected/<name>.out` (and `.aborts` and `.stderr`
for the expected aborts); rejections go in `test/errors_tc/` with
`// error:` markers. Programs with workers run natively (TinyCC refuses
them); the others run on every backend. Every fixture writes the files it
maps under a scratch directory of its own.

**Step 0**, `resource<U>`:

| Fixture | Checks |
|---|---|
| `test/typing/resource_values.goose` | a binding's kind with no C: the zero default from `default<resource<T>>()`, a global with its type alone, a literal's `..` and a missed `qpoll`; handles in structs, arrays and payloads, copied, sent through a queue and to a worker; `print` of a handle and of a struct holding one (the type alone) |
| `test/packages/pkg_resource` | a program with C of its own (as `pkg_own_c`): a binding's kind made and taken by its `extern fn`s, held in Goose storage, handed back to C, and C seeing the zero handle as 0 |
| `errors_tc/resource_compare.goose` | `==`, `!=` and the orderings on handles, and `==` of a struct holding one |
| `errors_tc/resource_arith.goose` | arithmetic and bitwise operators on a handle; `as` and `as!` to and from an integer |
| `errors_tc/resource_image.goose` | `to_bytes`, `bytes_of` and `from_bytes` of a type holding a handle; `hash` of one |
| `errors_tc/resource_extern_return.goose` | an `extern fn` returning a handle of a runtime kind, or a struct holding one |
| `errors_tc/resource_kind_value.goose` | a variable of type `mapping` or `frozen<i64>`, which name kinds |

**Phase 1**, positive:

| Fixture | Checks |
|---|---|
| `shared_map_views` | a file the test writes, mapped and viewed as `i64`, `i32`, `u32`, `u8` and a plain-data struct at aligned offsets; values, `size`, the whole file as `u8`, empty views, `from_bytes` from a mapped view |
| `shared_map_empty` | an empty file maps, size 0; `view<i64>(sh, m, 0, 0)` is empty |
| `shared_map_errors` | a missing file, a directory, a path with a NUL byte, an unreadable file: `false`, the zero handle and a reason |
| `shared_view_bounds`, `shared_view_align` (abort) | a view past the end, a misaligned run-time offset; the message names the file, type, offset, count and size |
| `shared_attach_zero`, `shared_attach_stale`, `shared_view_foreign` (abort) | the zero handle; an arena whose attachments all ended; a mapping of another arena |
| `shared_checkfree` (`// bce:elide`) | `checkfree` loops over views, two views of one morsel indexed together after one `assert` |
| `shared_workers` | handles as `thread_fn` arguments and in queue messages; 1, 2 and 16 workers summing one mapping; results checked |
| `shared_release` (`runtime-define: GS_SHARED_STATS=1`) | arenas released when the last attachment ends, by main or by a worker that outlives main's attachment; attachments ended by `break`, `continue`, `return` and `return … from`; the report on stderr |
| `shared_contained` (`GS_SHARED_STATS=1`) | a contained worker that aborts while attached and viewing; main continues; nothing left attached at the end |
| `shared_truncated` (abort) | the program truncates a file it has mapped and reads it: the diagnostic and exit status 1 |
| `shared_replaced` | a file replaced by rename (`write_file_atomic`) while mapped: the old mapping still reads the old bytes |
| `test/runtime/runtime_shared_lifecycle.c` | direct runtime test, like `runtime_threads_lifecycle.c`: attach/detach churn from many threads, no mapping or record leaked, stale detection, the serial and region limits with small test values, the SIGBUS message in a child process |

**Phase 1**, rejections, each with its diagnostic:

| Fixture | Rejects |
|---|---|
| `shared_view_outlives` | returning a view of a local attachment; a view bound outside the attachment's block |
| `shared_view_global` | storing a view of a local attachment in a global |
| `shared_view_write` | writing through a view, and through a function given one |
| `shared_view_queue`, `shared_view_spawn` | a view, or a struct holding one, put on a queue or passed to `thread_spawn` |
| `shared_view_type` | `view<bool>`, `view<Shape>` (an enum), `view<u8[..4]>`, `view<i64&>`, `view<resource<mapping>>` |
| `shared_view_align_const` | `view<i64>(sh, m, 3, 1)` |
| `shared_owner_rules` | an attachment copied, passed or returned by value, stored by value in a struct or array, made as a temporary (`view<…>(attach(h), …)`), or passed to `thread_spawn` |
| `shared_owner_worker_global` | a worker using main's global attachment |

**Phase 2**, positive:

| Fixture | Checks |
|---|---|
| `shared_freeze` | push, append, index, write, freeze, view; a dynamic stack filled again after a freeze; an empty freeze; a dynamic stack never frozen; freezing through a `dynamic_stack<T>&` parameter |
| `shared_freeze_links` | self-relative chains and `self` links frozen and followed in another worker; a `checkfree` probe (`// bce:elide`) |
| `shared_hash_join` | the join of 8.3 at W = 1, 2, 4 and 16 and P = W and 4W, against a single-threaded reference, exactly |
| `shared_dicts` | main's dictionaries (8.2), viewed by every worker |
| `shared_handles_queues` | handles in messages and in frozen directories, from worker to worker |
| `shared_contained_phases` (`GS_SHARED_STATS=1`) | contained workers aborting while building, after freezing, and while probing; their dynamic stacks' slots recycled, their frozen regions kept, the arena released at the end |
| `shared_regions_reuse` (`GS_SHARED_STATS=1`) | arenas made and released repeatedly take no fresh slot after the first round; `trim_memory` returns the free slots' pages |
| `shared_dstack_budget` (abort, `runtime-define: GS_DYNAMIC_BUDGET=…`) | a budget of a few slots: the dynamic stack that finds them all in use aborts with the budget, the slot size, the count and the flag; frozen and live slots both count |
| `shared_dstack_limits` | `ds.items.check_length(n)` against the slot's reservation, refusing a count before any growth |
| `shared_freeze_aliases` (and again with `runtime-define: GS_DEBUG=1`) | whole-array references to `ds.items` kept across a freeze: a local `T[>..]&`, one in a holder, and a caller's `T[>..]&` parameter while the callee freezes through `dynamic_stack<T>&`. Afterwards each sees an empty array, a push through each lands in `ds.items` on its fresh slot (checked through `ds` and through the alias), and the frozen view still holds exactly what was frozen. Under `GS_DEBUG` the frozen slot is read-only, so a push that reached it would fault |
| `shared_freeze_alias_loops` | a loop that indexes and pushes through an alias of `ds.items` and freezes `ds` in its body, directly and through a callee, gives the results of the same loop over a fresh array per round; at `-O1`, read as `loop_shapes.goose` is, its C reloads the base after the freeze instead of hoisting it |

**Phase 2**, rejections:

| Fixture | Rejects |
|---|---|
| `shared_frozen_write` | writing a frozen view, and through a link loaded from one |
| `shared_frozen_outlives` | a frozen view, or a reference loaded from one, outliving its attachment |
| `shared_freeze_live_view` | freezing a dynamic stack while a slice or reference into `ds.items`' elements is live, directly, through a call, and taken through a whole-array alias (`a[..]` for `a: T[>..]&`) |
| `shared_freeze_types` | `freeze` of a dynamic stack whose `T` holds a plain reference, a slice, an optional, an `in pool` reference, an index type, an owner, or a variable-size field; each names the field |
| `shared_dstack_rules` | a dynamic stack copied, returned, sent, or made as a temporary; a `dynamic_stack<T>` of a variable-size `T` |
| `shared_freeze_kind` | freezing an ordinary array; `view` of a frozen handle at the wrong `T` |

A frozen handle used after its arena's release is the run-time case, and
phase 1's `shared_attach_stale` covers it: attaching is the only way to a
region. Phase 2 adds `shared_frozen_stale` (abort), a frozen handle kept in
a message past its arena's release and then attached.

Beyond the fixtures: the full suite (`python3 test/run_tests.py --exe
build/goose --cc clang -j 16`), the sanitizer job over the new runtime test
and fixtures, and the performance checks #3 and #4 report (the 2 GB sum
against `read_file` and `pread`; the join's build and probe throughput
against private copies of the tables, with the memory each uses).

## 15. Documentation plan

* **Specification.** Step 0: a new §3.12, `resource<U>` (4.1 of this
  note as rules), §1.1 (handles are flat), §7.10 (the `uint64_t` shape and
  the runtime's kinds as parameters only), §12's builtin table. Phases 1
  and 2: §1.1 (the root class's builtin owners), §1.2 (shared regions), §3.4
  (the owners' placement), §4.1 (no reference counting *of values*), §7.10
  (a pointer to §11.4), §9.2 (attachments as roots and read-back
  candidates), §9.3 (the new aborts, and what ends the program), §9.5 (views
  are read-only), §10.4 (the dynamic stacks' budget beside the data
  stacks'), §10.5 (a view's length), §11.2 (attachments are released at a
  worker's end and abort, before `thread_wait` returns), §11.3 (its first
  step, `dynamic_stack<T>`, no longer only future), a new §11.4 *Shared
  memory* with sections 4 and 5 of this note as rules, §12's builtin table,
  Appendix B (TODO items for section 17's deferred parts), C.2 (the owners
  are private).
* **Reference.** Step 0: `resource<U>` in section 24, *Calling C and being
  called from C*, where a binding's kinds are made. Phases 1 and 2: a
  subsection of section 22, *Threads*, "Shared memory", with a compiling
  example per form; adding both there keeps the later sections' numbers and
  anchors.
* **Standard library.** `trim_memory`'s entry (it also trims the free
  slots).
* **Implementation notes.** Sections 3 (`TY_RESOURCE`, owners, views'
  roots, read-back, freeze as a shrink, the type predicates), 5 (the view
  facts), 6 (representations, scope exits, parameters, dynamic stacks and
  their caches; 6.8, the hold stack) and 7 (the arena registry, counts, the
  dynamic stacks' budget, its slots and free list, mapping and the
  fallback, the fault handlers, trimming).
* **Testing.** The `test/shared/` category, `pkg_resource` and
  `runtime_shared_lifecycle.c` in the layout table.
* **Index.** This note in docs/index.md's design notes.

## 16. Phased plan

### Step 0: `resource<U>` (both tracks)

The foundation, landed on its own before either track's phase 1 uses it:
#3 carries it if #5 has not landed it, and #5 builds `resource<event>` on
it. It adds no runtime state and no builtin.

1. **Types.** `TY_RESOURCE` for any `U`: resolution, flatness, image
   safety, the zero default, the text form, comparisons and conversions
   rejected (4.1).
2. **The C boundary.** `uint64_t` by value, parameters and results.
3. **Codegen.** `gs_res`.
4. **Tests and documents**: section 14's step 0, section 15's parts for
   step 0.

Built (spec §3.12). Two changes from the above:

* **No runtime kinds yet.** Step 0 adds no kind of its own. The first phase
  that adds one (#3's `shared`, `mapping` and `frozen<T>`, or #5's `event`)
  declares it in the compiler and adds its one rule: an `extern fn` takes it
  but does not return it. Section 14's `resource_extern_return` and
  `resource_kind_value` move there, since they need such a kind.
* **Methods.** UFCS looks in the kind's namespace, so a binding's functions
  are its handles' methods (spec §11.1).

### Phase 1: mapped files, attachments and views (#3)

1. **The owner `shared`** (4.2): resolution, root-owner placement through
   the existing `isroot` paths, construction only at declarations.
2. **Builtins.** `attach`, `handle`, `map_file` (both forms), `size`,
   `view<T>` for mappings, with `PlainData`, constant alignment and the
   view's roots (4.4, 4.5); read-back candidacy of attachments.
3. **Codegen.** `gs_att`; the builtins as in section 9; the scope-exit
   action; `shared&` parameters.
4. **Runtime.** `runtime_shared.h`: the registry, serials and region
   numbers with their limits (4.1), counts, the hold stack and
   `gs_shm_release_held` from `gs_thread_main`; `map_file` on POSIX and
   Windows, and its fallback copy (5.5); views; unmapping at release; the
   fault handlers' mapping table; `GS_SHARED_STATS`.
5. **BCE.** A mapping view's length.
6. **Tests and documents**: section 14's phase 1, section 15's parts for
   mappings.
7. **Performance check**: the 2 GB sum on 1 and 16 threads, through views,
   `read_file`, and a `pread` shim, reported in GB/s (11.1 gives the C-level
   ceiling on this machine).

Phase 1 needs no dynamic stack: an arena holds mappings only, and frozen
handles are not yet made.

### Phase 2: dynamic stacks and frozen regions (#4)

1. **The owner `dynamic_stack<T>`** with its component `items` (4.6), and
   `Freezable` (4.7).
2. **Builtins.** `freeze` (the shrink check, `Freezable`, the result),
   `view` of a frozen handle, `view<T>` with `T` checked against the
   handle.
3. **Codegen.** `gs_dstack` with its own stack block; the component as a
   resizable whose stack is that block; `freeze` as a rebase of `ds.items`
   for the caches, in the freezing function and through effect summaries
   (section 9); `dynamic_stack<T>&` parameters split; `--dynamic-budget`.
4. **Runtime.** The budget (one reservation, slots, their states and free
   list, the limit's abort), the fault handlers' slot lookup, `trim_memory`,
   freeze, frozen views, the debug-build protection.
5. **BCE.** `freeze` as `clear`.
6. **Tests and documents**: section 14's phase 2, section 15's remainder.
   Marking std's `hash` functions `checkfree` (they have no checks) lets the
   join's loops use them.
7. **Performance check**: the join at W = 16 with 16M build rows and 64M
   probe rows; build and probe rows/s; the probe against private copies of
   the tables through queues, and both approaches' memory.

### Later

Option A's collection of dynamic stacks, recoverable limits, variable-size
and multi-component frozen values, recoverable `attach`, a prefetch hint,
verified views of frozen bytes, index types and base-relative links into
frozen arrays: section 17.

## 17. Open questions

Each with the recommended answer.

* **Should `attach` have a form that fails instead of aborting**, for a
  server that receives handles from clients it does not trust to keep them
  alive? *Recommended:* not in v1. An owner cannot be a result, so it would
  be a declaration form (`let sh, ok = attach(h);`); add it when a program
  needs it.
* **Option A's collection of dynamic stacks**, a run-time number of them in
  one owner (P partitions on P dynamic stacks). *Recommended:* the next step
  after this design, generalizing `dynamic_stack<T>` rather than adding a
  second concept: its elements draw slots from the same budget and freeze
  as a single one does (4.6). Until then, write-combining buffers onto one
  dynamic stack per worker (8.3) are how radix partitioning is usually made
  fast anyway.
* **Recoverable limits**, option A's "opening document 257 returns a
  recoverable limit error". *Recommended:* with the collection, where the
  limit is a count the program chose; a single declaration aborts with the
  budget's numbers, as a data stack's overrun ends the program, and
  `check_length` is the explicit check before growth (4.6).
* **Frozen values of several components** (a hash table's directory and
  entries, a dictionary's offsets and bytes, as one frozen root struct
  viewed as a `const R&`). *Recommended:* later; v1 freezes one array per
  dynamic stack and a program groups handles in a flat struct (8.2).
* **Variable-size elements** (a dynamic stack of `u8[]` strings, frozen and
  iterated sequentially). *Recommended:* later; offsets and bytes cover
  strings now.
* **A dynamic stack's size.** Every slot is a data stack's reservation, so
  the default budget holds 8,188 slots. *Recommended:* keep it, and pack
  small arrays onto a few dynamic stacks; a smaller slot size (one for the
  budget, or a hint on the literal, `dynamic_stack<T> { reserve: n }`)
  comes with the self-relative range checks a larger one would need, and
  can wait for a program with many small frozen arrays.
* **Per-region release inside an arena.** *Recommended:* no; an arena per
  lifetime (8.3's note on partitions) is the unit, and per-region counts
  were the design rejected in section 12.
* **A prefetch hint** (`sh.prefetch(m, offset, length)`, `MADV_WILLNEED` or
  `PrefetchVirtualMemory`). *Recommended:* not until a cold-scan workload
  shows a gain; 11.1 found none.
* **Huge pages for dynamic stacks** (`MADV_HUGEPAGE` on large slots, for
  probes' TLB misses). *Recommended:* measure in #4's join; it is invisible
  to programs.
* **Verified views of frozen bytes** (a `u8` dynamic stack holding an
  image, viewed in place as a `T` array after `from_bytes`'s verifier).
  Sound, since frozen bytes cannot change after the check. *Recommended:*
  later, when a program needs to share images it did not build as typed
  arrays.
* **Index types into frozen arrays**, and base-relative links from one
  frozen region into another (a directory's entries pointing at rows).
  A frozen array's length never changes, so `u32 in r` would be sound, but
  index types name a global by its declaration. *Recommended:* later; use
  indices and one check per use, or self-relative links within one region.
* **Comparing handles.** Option C allows no comparison, and nothing in this
  design needs one. *Recommended:* none; if a program comes to need to know
  whether two handles name the same thing, a named builtin
  (`same_resource(a, b)`), never an operator.
* **Member calls with type arguments.** `sh.view<i64>(m, offset, count)`
  would read better than `view<i64>(sh, m, offset, count)`, but a member call
  takes no type arguments today, for any function (Appendix D's grammar has
  them only after a name). *Recommended:* not part of this feature; it is a
  parser change for every generic function, to make on its own merits.
* **Handles as dictionary keys.** *Recommended:* no hashing, as option C
  says: it would hand code a handle's bits; key by what the handle stands
  for (a row group, a partition).
* **Processes.** Sharing regions between processes (`shm_open`, memory
  files) would need a cross-process registry and different failure
  semantics. *Recommended:* out of scope.

## References

Spec sections referred to above:
[§1.1 size classes](../goose_spec.md#11-size-classes),
[§1.2 memory model](../goose_spec.md#12-memory-model),
[§3.4 placement](../goose_spec.md#34-placement-rules-what-may-contain-what),
[§3.9 relative references](../goose_spec.md#39-relative-references),
[§3.10 slices](../goose_spec.md#310-slices),
[§3.11 index types](../goose_spec.md#311-index-and-bound-types),
[§4.1 values](../goose_spec.md#41-everything-is-a-value-passing-by-size-class),
[§5.1 grow-only arrays](../goose_spec.md#51-grow-only-),
[§7.8 recursion](../goose_spec.md#78-recursion),
[§7.10 `extern fn`](../goose_spec.md#710-extern-fn),
[§7.14 `checkfree`](../goose_spec.md#714-checkfree-fn-no-bounds-check-left),
[§9.2 roots](../goose_spec.md#92-roots-and-the-depth-check),
[§9.3 runtime checks](../goose_spec.md#93-what-the-runtime-still-checks),
[§9.4 type-safe reuse](../goose_spec.md#94-type-safe-reuse-and-stale-references),
[§9.5 writability](../goose_spec.md#95-writability),
[§10.4 runtime environment](../goose_spec.md#104-runtime-environment),
[§10.5 bounds-check elimination](../goose_spec.md#105-bounds-check-elimination),
[§11.2 concurrency](../goose_spec.md#112-concurrency),
[§11.3 dynamic stacks](../goose_spec.md#113-dynamic-stacks-future);
[implementation.md §3.4 roots](../implementation.md#34-roots-and-provenance),
[§6.2 stack assignment](../implementation.md#62-stack-assignment),
[§6.8 threads and queues](../implementation.md#68-threads-and-queues),
[§6.10 stack-top caching](../implementation.md#610-loop-invariant-views-and-stack-top-caching),
[§7 the runtime](../implementation.md#7-the-runtime);
[owning_dynamic_data.md](owning_dynamic_data.md),
[coroutines.md](coroutines.md),
[root_structs.md](root_structs.md),
[relative_references.md](relative_references.md),
[serialization.md](serialization.md),
[string_constants.md](string_constants.md),
[scope_exit_cleanup.md](scope_exit_cleanup.md),
[wasm.md](wasm.md).

Outside this repository: more-fast-db's `docs/architecture.md`,
`docs/format.md`, `docs/source.md` and `docs/sched.md`; the Linux
`mmap(2)`, `madvise(2)` and `mprotect(2)` manual pages; Microsoft's
`CreateFileMappingW`, `MapViewOfFile` and `SetEndOfFile` documentation;
Crotty, Leis and Pavlo, "Are You Sure You Want to Use MMAP in Your Database
Management System?" (CIDR 2022), whose case against `mmap` (TLB shootdowns
at eviction, I/O stalls in page faults, no error handling) concerns a
database whose working set exceeds memory and which writes through its
mapping; this design maps read-only files the program assumes are cached,
and reports the one error a mapping can raise.
