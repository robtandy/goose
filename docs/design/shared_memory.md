# Immutable shared memory: mapped files and frozen regions

<details>
<summary>Table of contents</summary>

- [1. Decisions](#1-decisions)
- [2. The boundary today](#2-the-boundary-today)
- [3. The model](#3-the-model)
- [4. The declarations](#4-the-declarations)
- [5. What happens at run time](#5-what-happens-at-run-time)
- [6. A partitioned hash join](#6-a-partitioned-hash-join)
- [7. The generated C](#7-the-generated-c)
- [8. The compiler's pieces](#8-the-compilers-pieces)
- [9. Alternatives considered](#9-alternatives-considered)
- [10. Testing](#10-testing)
- [11. Documentation](#11-documentation)
- [12. The plan](#12-the-plan)
- [13. Deferred and open](#13-deferred-and-open)

</details>

Goose threads share no mutable memory (§11.2), so workers read copies. This note
proposes sharing what nothing can write while any thread can see it: a mapped
file, or an array that a thread built on a dynamic stack and froze. Such a
region belongs to a shared arena, and any thread reads it in place through
`const` views rooted at its attachment. Handles are option C's `resource<U>`
(owning_dynamic_data.md), step 0, shared with inboxes_select.md. Written against
`a646a68`. Step 0 is #9 and phase 1 #3, implemented (spec §3.12, §11.4); phase
2 is #4, not implemented.

## 1. Decisions

* **One mechanism, two kinds of region**: mapped files and frozen arrays.
* **Handles are option C's `resource<U>`, as written**: one opaque `u64`.
* **`resource<U>` is step 0**, also under the messaging design's events.
* **The root is an attachment**, a root owner; every view is rooted at one.
* **A view is a `const` slice**, so code that takes slices takes views.
* **An arena lives while it is attached**: attachments, not values, count.
* **One thread maps a file, and every thread views it**, as plain data only.
* **No prefaulting or advice by default**: measured, neither helped.
* **Truncation ends the program**; writes in place are outside the guarantee.
* **Frozen data is built in place**, on a `dynamic_stack<T>`, the first step of
  §11.3 and option A, which `freeze` hands to an arena without a copy.
* **What can be frozen** is what may cross threads, and self-relative links.
* **Released regions are recycled, not unmapped**; `trim_memory()` frees pages.
* **Aborts release what a worker holds**, before `thread_wait` returns.
* **No atomics, locks, memory orderings or `unsafe` in the language.**
* **Two deviations from the spec remain**: shared regions, counted attachments.
* **Step 0 and two phases**: `resource<U>` (#9); mapped files and views, on
  POSIX and Windows (#3); dynamic stacks and freezing (#4).

## 2. The boundary today

A reference is a raw address into one thread's stacks or static data (§1.2), and
the outlives rule follows one thread's scopes (§9.1), so only flat values cross
threads, by copy (§1.1), and an `extern fn` cannot return a slice, as C memory
has no root (§7.10). Option C leaves "direct mapped views" to "a separate design
connecting their bounds and lifetime to the resource"; this is that design, and
the missing root is the attachment. Copies cost, as summing a 2 GB `i64` file
from the page cache shows (`bench/shared_memory/mapbench.c`; `colsum.goose`):

| | 1 thread | 16 threads |
|---|---:|---:|
| `pread` into a buffer that each thread reuses | 9.5 GB/s | 73 GB/s |
| the whole file read first (as `read_file` does, 0.86 s), then summed | 2.2 GB/s | 2.5 GB/s |
| one shared read-only mapping, first pass | 16.4 GB/s | 143 GB/s |
| the same mapping, later passes | 20.4 GB/s | 158 GB/s |
| Goose: `pread`; `read_file` (its read 1.05 s), parts copied to workers | 9.3; 1.85 GB/s | 74; 0.9 GB/s |
| Goose: views of one mapping, first pass; later passes | 15.5; 20.1 GB/s | 137; 157 GB/s |

## 3. The model

No thread can write memory that another thread can read: shared memory is
immutable while anyone can see it, and no view outlives it. The compiler proves
the second half with roots (§9.2); the runtime checks the rest, that a handle
names live memory and a view fits its region, with a diagnostic, never undefined
behavior. Static data is shared so already, its views being `const` (§9.5); a
region adds a lifetime, its arena's, and contents a thread chose.

## 4. The declarations

Five names resolve as types (`resource`, `shared`, `mapping`, `frozen`,
`dynamic_stack`) and six as builtins: `attach`, and `handle`, `map_file`,
`size`, `view` and `freeze`, which take an attachment first and read as its
members (§7.1). Like builtin functions they are not keywords: a program's
function so named takes the plain calls it matches, and the builtin one naming
an attachment first (section 12); `::name` reaches one past a namespace
(§11.1). Every form parses today; `view<i64>(sh, …)` is a call, as `qget<T>()`
is, since a member call takes no type arguments (Appendix D).

### 4.1 `resource<U>`, the first step

`resource<U>` is option C as written: a fixed-size value, one `u64`, naming what
code does not reach into, such as a GPU buffer or an arena; `U` tags the kind,
and the bits are its binding's business. Code stores and copies it as any
fixed-size value (copying the name, keeping nothing alive) and passes it only to
APIs of its kind, but never dereferences it, computes with it, compares it
(`==`, `!=`, the orderings, nor `==` of a struct holding one), hashes it or
converts it to or from an integer (`as`, `as!`), so it cannot forge one. Being
fixed-size settles what option C leaves unsaid: a handle is flat (§1.1); its
default, all bits zero, names nothing (no binding hands out zero), and is what a
literal's `..`, a global declared by type and a missed `qpoll` give; `print`
writes its type, `resource<mapping>`; and it has no image, so `to_bytes`,
`bytes_of` and `from_bytes` reject a type holding one.

**Kinds.** A binding's tag is a type it declares (`struct GpuBuffer {}`, never
made), and its `extern fn`s make and take its handles as `uint64_t`, by value
(§7.10). The runtime binds `resource<shared>` (made by `sh.handle`, taken by
`attach`), `resource<mapping>` (by `sh.map_file`; `view<T>`, `size`) and
`resource<frozen<T>>` (by `sh.freeze`; `view`), where `mapping` and `frozen<T>`
name kinds, written only as `resource`'s argument. C may take these, seeing the
bits, as `gs_event_signal` does, but not make one: no result or value it writes
holds one, nor an export's argument. Cleanup stays open for bindings' kinds, as
in option C; the runtime's need none. A runtime handle's bits 63..24 are its
arena's serial, 1 to 2^40 - 1 and never reused, and bits 23..0 are 0 for the
arena itself or the region's number, 1 to 2^24 - 1 (`GS_RES_SERIAL_BITS`,
`GS_RES_REGION_BITS` in `runtime.h`); the runtime aborts, never wrapping. An
unknown serial is stale (5.1), and a region past its arena's count a defect.
Every runtime kind, events included, documents its encoding: no stale value
names a newer resource.

### 4.2 Attachments and views

```goose
let sh = shared {};      // a new arena, and this declaration's attachment to it
let sh2 = attach(h);     // h: resource<shared>; another attachment to h's arena
let h2 = sh.handle;      // resource<shared>, for other threads
```

**Attachments.** `shared` is a builtin root-class type (§3.4), made only by an
owning declaration, local or global, under every rule of root owners: functions
take `sh: shared&`, an unannotated binding borrows it, a root struct may hold a
`shared&`, and a worker attaches a handle, as it cannot use main's global
attachment, which lasts the run and may root views in globals. An attachment
ends at each exit of its scope, `return … from` included, in reverse order with
the scope's restores and `defer`s, and after a contained abort (5.4). Two in one
thread both count; having no components, one may be live across a call into a
recursive cycle (§7.8).

**Views.** A view is an ordinary `const T[:]` (C.2), used as any slice, kept in
`const` slots and checked once, when made. It is rooted exactly at its
attachment or, through a `shared&` parameter, at the class of the caller's
(implementation.md §3.4). An attachment's storage is every region of its arena,
and it is never an array receiver, so `index_of`, `range_index` and `free_slice`
never meet one. §9.2, unchanged, keeps views out of globals, outer holders and
messages and in the attachment's scope, while the runtime keeps the arena. An
attachment is a read-back candidate (§9.5) for every plain-data and freezable
type, as static data is for `u8`, so a view read back out of a container is
held to the attachments in scope, at a cost in precision.

### 4.3 Mapped files: `map_file` and `view<T>`

```goose
let m, ok = sh.map_file(path);        // resource<mapping>, bool
let m, ok = sh.map_file(path, why);   // with a failure's reason appended to why
let n = sh.size(m);                   // the file's size in bytes when mapped
let xs = view<i64>(sh, m, offset, count);
```

`map_file` maps the whole regular file `path` (UTF-8) read-only. A missing path,
a directory, device or FIFO, a path holding a NUL byte, a file the program may
not read or over 2^48 bytes (§10.4), and a mapping the system refuses give the
zero handle and `false`, with the system's reason where there is one; an empty
file maps, with size 0. `view<T>(sh, m, offset, count)` is `count` `T`s from
byte `offset`, checked once, by aborts of their own in §9.3's list rather than
checks that `checkfree` counts (§7.14). `T` is **plain data**, with every byte
pattern a value: integer and float scalars, and fixed arrays and structs of
plain data, pads allowed; not `bool`, enums, limited arrays, `varint`,
references, index types or handles, so bytes from outside need no validation
(§9.4), even while the file changes. `offset` is a multiple of `T`'s widest
scalar: loads are unaligned-safe (C.2), but mapped formats align arrays, so
misalignment means corruption. `0 <= offset`, `0 <= count` and `offset + count *
sizeof(T) <= sh.size(m)`, checked without overflow, so an empty view fits
anywhere up to the size, and `m` is a mapping of `sh`'s arena.

### 4.4 Dynamic stacks and `freeze`

```goose
var ds = dynamic_stack<Row> {};    // a grow-only array on a stack of its own
ds.items.push(Row { key: k, payload: v });
fill(ds.items);                    // any fn fill(out: Row[>..]&)
let r = sh.freeze(ds);             // resource<frozen<Row>>; ds.items is empty again
let rows = sh.view(r);             // const Row[:], rooted at sh
```

`dynamic_stack<T>` is a builtin root-class type whose one component, `items:
T[>..]`, is an ordinary grow-only array of a fixed-size `T`, alone on a stack
that is a slot of the budget (5.2). Its literal takes no fields and appears only
at an owning declaration; until frozen, `ds` is as private as any array, is
passed as `dynamic_stack<T>&` and, holding a resizable, is never live across a
call into a recursive cycle. `sh.freeze(ds)`, through any attachment in any
thread, is checked as `ds.items.clear()` is (§5.1): no reference or slice into
the elements may stay live, in a holder or through calls, and `T` must be
freezable (4.5). References to the whole array, in variables, holders or
callers' parameters, survive: they name `ds`'s own header and stack block, never
a slot, so they see `items` empty and grow it on the fresh slot, and codegen
reloads the moved base (section 7). Nothing is copied: the slot with the
`ds.items.len` elements becomes a region of `sh`'s arena, for the arena's life,
and `ds` starts over on a fresh slot; a slot never frozen returns to the free
list at its scope's exit. Only a dynamic stack can be frozen; an ordinary array
is published by appending it to one. This is option A with one stack: stable
data, release per slot, one budgeted reservation, an explicit limit
(`ds.items.check_length(n)`) and serials as identity. Decommits wait for
`trim_memory()` (5.2), and recoverable limits for option A's collection, which
generalizes `dynamic_stack<T>` with slots from the same budget, as a task's own
stacks would draw them (coroutines.md 6.1).

### 4.5 What can be frozen

`T` is **freezable** if it holds, at no depth, anything whose meaning depends on
the thread that made it. Scalars, `bool`, enums in fixed mode, fixed and limited
arrays and structs of these qualify, as flat values; so do handles, and
self-relative references, `T&<w>` and `T&<w>?`, which stay in the region (§3.9).
Plain references, slices and their optionals do not, as addresses in the
freezer's stacks; nor do `in pool` references, measured from a global that each
thread copies; index and bound types, proven against one thread's copy (§3.11);
root owners; or variable-size values, in v1. A `freeze` of another `T` names the
field path and the reason. These are the types that may cross threads today,
plus the self-relative references, which survive uncopied. `sh.view(r)` is the
whole frozen array, a `const T[:]` rooted at `sh`, and `view<T>(sh, r)` must
name `r`'s `T`. A link loaded from it is a `const T&` or `const T?` rooted at
`sh`, for an addition and no check, as its store was checked and the region
never changes; links are made before the freeze, under the same-root rule. A
link that a `pop` left past the end (§9.4) reads the same element afterwards, as
a region keeps all that its dynamic stack wrote, and a recycled slot shows
nothing of an earlier owner's. Copying elements that hold links out of a view is
rejected, as from any array. So one worker builds a hash table chained by links,
and all probe it with no check beyond the bucket index, which `%` by its length
proves (`bench/shared_memory/join_loops.goose`).

### 4.6 Mutation, threads and the rest of the language

**Mutation** is rejected by type, as views and their links are `const` (§9.5);
by ownership, as a region's only writable access is a dynamic stack in one
thread, which reaches nothing of it once frozen; and, against compiler defects,
by the hardware: mappings are read-only (`PROT_READ`, `PAGE_READONLY`), as
frozen regions are in a debug build (`GS_DEBUG`) only, since protecting costs
about 20 µs per MB with other threads running (`bench/shared_memory/mprot.c`).
Handles cross threads as spawn arguments, messages, copied globals or fields of
a frozen region. A thread attaches once, for an atomic increment (11 ns alone,
1.0 µs with 16 threads at once; `bench/shared_memory/attach.c`), and then makes
views freely. Generics are checked per instantiation, naming the chain, and a
binding's tag may be generic (`resource<Texture<f32>>`). For bounds-check
elimination a mapping view's length is its `count`, a frozen view's is fixed,
and `freeze` kills the length facts of `ds.items` and of its aliases. A
coroutine frame holding handles is flat (coroutines.md 4.9), and rule R1
extends to both owners, which no frame can hold and a dropped frame would never
end; views rooted outside a coroutine cross yields under R4.

### 4.7 What is rejected

| At compile time | Diagnostic |
|---|---|
| a handle compared, computed with, hashed, converted or serialized | each operation's error; `ImageSafe`'s "a handle names something only its binding can read" |
| an `extern fn` returning a runtime handle or a value holding one, or taking writable storage holding one; an `export fn` taking one | names the handle: C never makes one (§7.10) |
| a view outliving its attachment, written through, stored in a slot not declared `const`, or crossing threads | §9.2's, §9.5's and §11.2's, unchanged |
| an owner copied, returned, stored by value, sent, made as a temporary or outside an owning declaration; a worker using main's | the root-owner diagnostics (§3.4, §11.2) |
| `view<T>` of a mapping at a `T` not plain data, or a constant misaligned offset | names the part of `T` at fault |
| `freeze(ds)` while a reference or slice into `ds.items`' elements is live | §5.1's shrink error |
| `freeze(ds)` of a `T` not freezable | names the field path and the reason |
| `dynamic_stack<T>` of a `T` not fixed-size; `freeze` of anything else; `view<T>(sh, r)` at another `T` | an error, its wording not fixed here |
| an attachment or a dynamic stack in scope at a coroutine's suspension point | R1's |

| At run time | Result |
|---|---|
| `attach` of a released arena | abort: the arena was released because no attachment was left, and where |
| `attach` or a view of the zero handle; a view of another arena's region | abort, saying so |
| a mapping view out of bounds or misaligned | abort, naming the file, the type, offset and count, and the size |
| the 2^40-th arena; the 2^24-th region of one arena | abort: "shared arena serials are used up"; "a shared arena holds at most 16,777,215 regions" |
| a dynamic stack when every slot is in use | abort, giving B, R, N and the flag that raises B |
| a dynamic stack growing past its slot | ends the program, naming it, as a data-stack overrun does |
| a mapped file truncated or unreadable | ends the program (5.3) |

## 5. What happens at run time

### 5.1 Arenas, counts and stale handles

An arena is a runtime record outside every data stack, as a queue is: a
never-reused serial, a count, and an append-only table of regions (base, byte
length, kind, a mapping's path) under the registry's lock. `shared {}` registers
one, counted 1, in a process-wide table by serial; `attach(h)` looks the serial
up under the lock and increments a count above zero, or aborts; the decrement to
zero at an attachment's end unregisters and releases the arena (5.2). Only
attaching declarations and their exits change the count, never handles or views,
so a worker attaching once changes it twice. Where main attaches, spawns and
waits, its scope's exit is the release point, as `thread_wait` returns only
after a worker's attachments end. Handing an arena on takes an attachment until
the receiver has its own, or the receiver's `attach` aborts: a reported liveness
error, never a dangling view. A stale handle can be copied and sent but not
attached, so no view of released memory exists; as handles are never forged or
returned by C and serials never recur, none names a newer arena.

### 5.2 The dynamic stacks' budget, release and reuse

The first slot needed reserves `GS_DYNAMIC_BUDGET` bytes, B (16 TB by default,
`--dynamic-budget`), as one inaccessible range (`PROT_NONE`; `VirtualAlloc`'s
`MEM_RESERVE`) of slots of R + G: R usable, a data stack's `GS_STACK_RESERVE` (2
GB), and a guard gap G, `GS_STACK_GAP` (1 MB). N = B / (R + G), 8,188 by
default, meets option A's N * (R + G) + H <= B, the slot records H apart; a
refused range is halved, down to one slot, as `gs_reserve_region` does;
`GS_SHARED_STATS` reports it. A slot is fresh, live, frozen or free (released,
pages committed). A dynamic stack takes a free slot, else a fresh one, opened by
`mprotect` or committed on touch (Windows), and with all N live or frozen aborts
with B, R, N and the flag that raises B. R being a data stack's reservation, a
`u32` link needs no range check (§3.9); growth past R hits the gap and ends the
program unless `ds.items.check_length(n)` refused it. The stack control block is
the dynamic stack's, not the slot's: it sits in the descriptor beside `items`'
header and points into the current slot, so pushes and functions that grow
arrays through references work unchanged, and a `gs_rref` stays good across
freezes.

**Freezing** records the slot in the arena with the array's byte length
(protecting it first in a debug build), takes a fresh slot, a free one if it
can, and points block and header at its start with length 0: the one change of a
grow-only array's base, a rebind to codegen (section 7). A frozen slot keeps all
of R, so small arrays share dynamic stacks; per-morsel dictionaries take three
regions, offsets, bytes and a directory. The fault handlers find a slot
arithmetically and commit (Windows) in a live slot, or report an overrun in a
gap or a write to a protected frozen slot; slots need no region-registry entry,
so `hardware_threads()` holds. Releasing an arena puts its frozen slots on the
free list, pages committed, has the releasing thread unmap its mappings
(`munmap`, `UnmapViewOfFile`), and frees the record. A free slot is taken before
a fresh one, so arenas built and dropped repeatedly fault no pages after the
first round; an unfrozen slot joins the list at its exit or after a contained
abort. No slot is unmapped while the program runs, which keeps, as option A
says, the reservation that guarantees reuse of the budget; `trim_memory()`
(§1.2) returns free slots' pages as it does stacks', since unmaps by threads
ending together serialize: 80 ms for 16 threads, 4.8 ms for one
(`bench/shared_memory/release.c`).

### 5.3 Mapping a file

Any thread may map, but one thread mapping each file once gives one system call
and one set of page tables, shared by every thread and kept across scans. A
regular file that the system will not map (`/proc`, a file system without
`mmap`) is read into anonymous memory, made read-only and handled as a mapping,
as on a platform with no `mmap`. The runtime neither prefaults nor advises, as
neither helped (`bench/shared_memory/mapbench.c`); advice is invisible, so it
may come later. A read past the new end of a truncated file raises SIGBUS
(`bench/shared_memory/sigbus.c`), which nothing prevents (no mandatory locks;
seals are for memory files) and nothing recovers from soundly, as the fault can
hit inside the runtime's C. So the handler finds the mapping, writes `goose
runtime error: <path> was truncated or could not be read while mapped: a read at
byte <offset> faulted` and ends the process, in a contained worker too, as for
guard pages (§11.2); a write fault in a mapping is reported likewise. Writes in
place by another process are outside the guarantee: views may read old and new
bytes mixed, but plain data keeps every pattern a value, and generated code
checks each index it loads, so no changed byte leads outside a region.

| | Mapping a file | A failed read |
|---|---|---|
| Linux, macOS | `open(O_RDONLY \| O_CLOEXEC)`, `fstat`, `mmap(PROT_READ, MAP_SHARED)`, the descriptor closed | SIGBUS |
| Windows | `CreateFileW(GENERIC_READ, FILE_SHARE_READ \| FILE_SHARE_DELETE)`, `CreateFileMappingW(PAGE_READONLY)`, `MapViewOfFile(FILE_MAP_READ)`, the file kept open | `EXCEPTION_IN_PAGE_ERROR` |

Windows is stricter: a mapped file cannot be truncated
(`ERROR_USER_MAPPED_FILE`), and without `FILE_SHARE_WRITE` no other process may
open it to write; a rename, as everywhere, changes no mapping. TinyCC compiles
the same runtime C, and refuses programs with workers (Appendix E); wasm
(wasm.md) would copy files and use its partitions for the budget. A big-endian
host aborts at `map_file` with `GS_E_ENDIAN` (serialization.md §3).

### 5.4 Contained workers, `thread_wait` and ordering

Each thread keeps its attachments and dynamic stacks on a runtime stack: a
declaration pushes its arena or slot (a freeze swaps the slot), and its exits
pop it. A contained worker's abort (§11.2) skips the exits, and then
`gs_run_contained`'s caller pops the whole stack, ending each attachment and
freeing each unfrozen slot, before releasing the worker's data stacks. The
regions it froze stay for its peers; an arena's last attachment releases it.
`thread_wait(id)` returns once "all of its Goose storage has been released",
these included, so a thread that waited for every worker holds the only
attachments left. `exit`, an uncontained abort, a fault, or `main` returning
releases nothing, leaving it to the process's end. A worker may outlive its
spawner, keeping its arenas.

**Ordering.** A region is complete before its handle exists, and a handle
reaches a thread only by a spawn, a queue, a global copied at spawn or a frozen
region that came so, each ordering the sender's writes before the receiver's
reads: a queue by its lock now, or the release and acquire that any correct
queue, the messaging design's included, keeps. A region's record is read under
the registry's lock, once per region and attachment (section 7); the count is an
acquire-release atomic, so whoever releases an arena sees every reader done.
These belong to the runtime, not to the language (reference section 22).

## 6. A partitioned hash join

Main maps both sides' columns, gives W contained workers a `Job` of handles and
P, and collects each phase's results before queuing the next. A worker
partitions build morsels onto two dynamic stacks, as P is known only at run time
and a dynamic stack is a declaration; builds tables of chain heads and rows
linked by self-relative references from every worker's runs; and probes them.
`partition`, `build` and `probe_all` run `join_loops.goose`'s loops over views.

```goose
struct Partitioned { rows: resource<frozen<Row>>, runs: resource<frozen<Run>> }
struct Task { part: i64, inputs: resource<frozen<Partitioned>> }   // part < 0 ends phase 2
struct Built { part: i64, table: resource<frozen<Entry>>, heads: i64 }

thread_fn join_worker(job: Job) {
    let sh = attach(job.arena);                          // one attachment, three phases
    var rows = dynamic_stack<Row> {};
    var runs = dynamic_stack<Run> {};
    partition(sh, job, rows.items, runs.items);          // views of the build morsels
    qput(Partitioned { rows: sh.freeze(rows), runs: sh.freeze(runs) });
    var t = dynamic_stack<Entry> {};
    loop {
        let task = qget<Task>();
        guard task.part >= 0 else { break; }
        let heads = build(sh, sh.view(task.inputs), task.part, t.items);
        qput(Built { part: task.part, table: sh.freeze(t), heads: heads }); // t is empty again
    }
    var tables: (const Entry[:])[..1024] = [];
    for b in sh.view(qget<resource<frozen<Built>>>()) { tables.push(sh.view(b.table)[..b.heads]); }
    qput(probe_all(sh, job, tables));                    // views of the probe morsels
}
```

Main freezes the `Partitioned` values into the tasks' directory and the `Built`
ones in partition order; its attachment's end, after its `thread_wait`s, unmaps
the files and recycles every slot; partitions wanted back sooner go in a second
arena that workers leave after phase 2. As an aborted worker's results never
come (5.4), a real main collects with a timed `qget<T>(ms)`, or `select`.

## 7. The generated C

A handle is a `gs_res`, one `uint64_t`. An attachment is a `gs_att` in its
frame, its arena and the region it looked up last; `shared&` passes its address.
A dynamic stack is a `gs_dstack`: the `gs_slot *` it has, its own `gs_stack`
block pointing into that slot, and `items`' `gs_rhdr`; `ds.items` as a `T[>..]&`
is `gs_rref { &ds_g.items, &ds_g.stack }`, which no freeze changes. A
`dynamic_stack<T>&` parameter is split as root parameters are
(`FindSplitRootParams`); a frozen one keeps the descriptor's address, by the
rule for parameters handed to builtins, so the freeze updates the caller's. The
owners' ends are scope entries beside restores and `defer`s
(`EmitExitRestores`). A view's address comes from an inline check of that
region, a compare of the handle and three of the bounds; the loop over it is
today's, and a program using none of this compiles to the C it does today.

**A freeze is a rebind** of `ds.items`, the one operation that moves a grow-only
array's base: the cached top is written back first, no cached base, length or
top crosses it, and a loop that may freeze hoists none (`hoistrefs`,
`hoistfields`). A specialization that may freeze, itself or through a call,
records in its effect summary the components it may rebase, and calls to it
reload the caller's caches of every reference that may reach one, as for stack
tops (`SyncReach`); otherwise a stale base would write the frozen slot. The
runtime's entry points are in section 8.

## 8. The compiler's pieces

| Piece | Change |
|---|---|
| Resolution (`resolve.h`) | step 0: `resource<U>`, where the program declares no such name, is a new `TY_RESOURCE` whose `sub` is the kind. Phase 1 (or #5, first): `shared`, `mapping`, `frozen<T>` and `event` are the runtime's kinds |
| Types (`typecheck_types.h`) | step 0: `IsFlat` holds and `ImageSafe` fails ("a handle names something only its binding can read"); the zero default; `as`, `as!` and comparisons refused where `==` refuses a function value (`typecheck_exprs.h`), structural `==` included; printing the type's name (`codegen_render.h`). Then `PlainData(t, why)` and `Freezable(t, why)`, the latter from `HoldsPlainRef`, `HoldsIndexT` and `ImageSafe`'s `in pool` test |
| The C boundary (`CheckExternSpec`, `CheckExport`) | step 0: `uint64_t` by value. With the runtime's kinds (`RuntimeHandleIn`): no result holding one, no writable reference, slice or builder to storage holding one, and no export's parameter |
| Owners | `shared` and `dynamic_stack<T>` are builtin struct declarations with the `isroot` mark and a builtin-owner kind, so every root struct rule applies unchanged; their constructors only initialize owning declarations |
| Builtins (`builtins.h`, `typecheck_builtins.h`) | `attach`, `handle` (`BF_PROPERTY`), `map_file`, `size`, `view` (`BF_TYARGS`, optional) and `freeze`, with an attachment receiver beside `BuiltinRecv`'s array kinds, checked in `CheckBuiltin`; a view's `Val` has the receiver's roots and exactness (`RootedAtReceiver`) and is not writable; `freeze` is a shrink of `ds.items` (`CheckGrowShrink`, `BF_SHRINKS`), logged in the shrink summary for callers |
| Read-back, bounds checks (`RootCandidates`, `HoldsByValue`, `bce.h`) | an attachment holds every plain-data and freezable type by value, as `StaticCanContain` does; the facts of 4.6; views' own checks are aborts, and `Call::nobc` is not involved |
| Codegen | step 0: `CT` of a handle is `gs_res`. Then the owners' `CT`s (`codegen_types.h`), the builtins (`codegen_builtins.h`), their ends beside `RegisterDefer`'s, `shared&` and split `dynamic_stack<T>&` (`codegen_frames.h`), and freeze as a rebind for stack-top caching and view hoisting (implementation.md §6.10) |
| Coroutines, driver, editors | R1's check (`CycleCallTemps`) covers both owners, once coroutines exist; `--dynamic-budget size` writes `-DGS_DYNAMIC_BUDGET`, as `--stack-reserve` writes `GS_STACK_RESERVE`; the language server's hover and completion come from the builtin table; no lexer, parser or formatter change, and no new keyword |
| Runtime | `runtime.h` declares, and a new `runtime_shared.h` after `runtime_threads.h` defines: `gs_shm_new(gs_att *, loc)`, registering a new arena, attached once, or aborting when serials are used up; `gs_shm_attach(gs_att *, gs_res, loc)`, under the registry's lock, aborting for a stale or zero handle; `gs_shm_detach(gs_att *)`, releasing at zero and popping the hold; `gs_shm_map_file(gs_att *, path, len, gs_res *, why, whylen, loc)`, the reason a message as `thread_wait`'s is, registering the mapping for the fault handlers; `gs_shm_size(gs_att *, gs_res, loc)`; the inline `gs_shm_view(...)`, against the region `gs_att` looked up last, and `gs_shm_view_slow`, which looks one up and aborts for another arena's or a misfit; `gs_shm_frozen(gs_att *, gs_res, elemsize, int64_t *len, loc)`; `gs_dstack_open(gs_dstack *, loc)` (`GS_E_BUDGET`, reserving the budget on first use) and `gs_dstack_close(gs_dstack *)`; `gs_shm_freeze(gs_att *, gs_dstack *, elemsize, loc)`; `gs_shm_release_held(void)`, for a contained abort; and `GS_SHARED_STATS`, a report at exit for tests. In `runtime_impl.h`, `gs_fault_handler` and `gs_fault_filter` look up mappings and slots, and `gs_trim_memory` trims free slots; `gs_thread_main` calls `gs_shm_release_held()` after a contained abort, before `t->release()`; `runtime_inline.h` is regenerated |

## 9. Alternatives considered

* **Views rooted at the handle**: a handle is copied, and a root is one scope.
* **Counting handles or views**: an atomic per copy, and destructor types.
* **Attaching each region**: phase 3 of a join needs all the tables at once.
* **A two-word handle with `==`**, the first form: option C's `u64` suffices.
* **`builder<T>`**: Goose calls `T[>..]` a builder; what is new is memory.
* **An owner that waits for its attachments**: it deadlocks with a waiter.
* **A release proved by `thread_wait`**: handles travel through queues.
* **Epochs (RCU)**: a blocked thread stalls reclamation.
* **Freezing ordinary arrays**: a copy, or a remap that only Linux has.
* **Verified views of mapped files**: a tag or link can change after the check.

## 10. Testing

Positive fixtures go in a new `test/shared/`, rejections in `test/errors_tc/`
with `// error:` markers (docs/testing.md); programs with workers run natively
only, and each fixture maps files under a scratch directory of its own.

| | Fixtures |
|---|---|
| Step 0 | `typing/resource_values` (defaults, storage, `print`), `threads/resource_threads` (queues, workers); `packages/pkg_resource` (a binding's C); a rejection for each operation 4.1 forbids. With the first runtime kind: a variable of a kind, and an `extern fn` returning one |
| Phase 1 | views of every plain type; empty files and failures; `checkfree`; 1, 2 and 16 workers on a mapping; a rename while mapped; release and contained aborts under `GS_SHARED_STATS`; each check of 4.7; `runtime/runtime_shared_lifecycle.c` (churn, leaks, stale handles, the limits at small values, SIGBUS in a child) |
| Phase 2 | freezing and links; section 6's join at W = 1, 2, 4 and 16 and P = W and 4W, against a single-threaded run; main's dictionaries; handles in queues; aborts in each phase; slot reuse; the budget and `check_length`; each check of 4.7; and the aliases: a local alias, one in a holder and a caller's each see `ds.items` empty after a freeze and push onto the fresh slot, also under `GS_DEBUG`; a loop that pushes through an alias and freezes reloads the base in its `-O1` C; an alias's slice blocks a freeze |

## 11. Documentation

Two deviations remain, for one reason: the scopes that see shared memory are in
different threads, so no one thread's scope can own or free it. An upstream
review should start with them.

* **A third kind of memory.** §1.2 puts all dynamic allocation in values on data
  stacks owned by locals or globals, which go when their thread ends (§11.2). A
  live dynamic stack is still one (§11.3); frozen ones and mappings are an
  arena's while its attachments' scopes last. No heap, and nothing moves.
* **The runtime counts attachments.** §4.1 rules out reference counting and any
  deallocation but a scope exit, but which threads attach is known only at run
  time, as handles travel through queues. Only attaching declarations and their
  exits count, and no destructor runs: the owners live only at declarations,
  are never copied or stored, and end as a stack restore does, even after a
  contained abort. §4.1 says "no reference counting of values"; the README
  stays true.

| | Specification | Elsewhere |
|---|---|---|
| Step 0 | new §3.12, `resource<U>`; §1.1 (flat), §7.10 (`uint64_t`; runtime kinds as parameters only), §12 | the reference's section 24 |
| Phases 1 and 2 | new §11.4, *Shared memory*, sections 4 and 5 as rules, cited by §1.2 (which gains *shared regions*), §4.1 and §7.10; §1.1 and §3.4 (the owners), §5.1 (`freeze`, the shrink that restarts the array on new memory, which whole-array references follow), §9.2 (attachments as roots and read-back candidates), §9.3 (the new aborts), §9.5 (read-only views), §10.4 (the budget beside the data stacks'), §10.5 (view lengths), §11.2 (attachments and dynamic stacks released before `thread_wait` returns; a truncated mapping and a dynamic stack's overrun end the program, beside guard-page hits), §11.3 (its first step), §12, Appendix B (section 13), C.2 (the owners are private) | the reference's section 22, with an example per form; `trim_memory` in the library; the implementation notes' sections 3 (the checker), 5 (view facts), 6 (codegen, the hold stack) and 7 (the runtime); docs/testing.md |

## 12. The plan

### Step 0: `resource<U>` (both tracks)

#9 lands it before either track's phase 1; the messaging design builds
`resource<event>` on it. It adds no runtime state and no builtin.

**Built**, with two changes: no runtime kind until phase 1, which declares them
with their rule and the two fixtures that need one; and a UFCS call looks in the
kind's namespace, so a binding's functions are its handles' methods (§11.1).

### Phase 1: mapped files, attachments and views (#3)

**Built**: `shared`, `attach`, `handle`, both `map_file`s, `size` and mapping
views, every piece of section 8 but those of dynamic stacks and `freeze`, on
POSIX and Windows, with four changes. A program's function named like a builtin
takes the plain calls it matches, and the builtin a call naming an attachment
first: one applying only where nothing is so named hid views from a program
with a `view`. C makes no runtime handle in storage it writes, or as an export's
argument. An attachment keeps the region it looked up last, so the inline check
reads its own thread's record, with no atomic; one lock guards the registry and
the tables. And `why` comes back as `thread_wait`'s message. Numbers: section 2.

### Phase 2: dynamic stacks and frozen regions (#4)

`dynamic_stack<T>`, `Freezable`, `freeze` and frozen views: the rest of section
8, the budget's slots and faults, `trim_memory` and debug protection; std's
`hash` marked `checkfree`, as it has no checks. Check: the join at W = 16, 16M
build and 64M probe rows, in rows/s, against private copies of the tables sent
through queues, with each's memory.

## 13. Deferred and open

* **A failing `attach`**, `let sh, ok = attach(h);`: once a program needs it.
* **Option A's collection of dynamic stacks**, with recoverable limits: next.
* **Frozen values of several components, or of variable size**: later.
* **Smaller slots** (`dynamic_stack<T> { reserve: n }`): keep R; pack arrays.
* **Per-region release within an arena**: no; use an arena per lifetime.
* **A prefetch hint**, `sh.prefetch(m, offset, length)`: once one shows a gain.
* **Huge pages for large slots**: measure in #4's join; invisible to programs.
* **Verified views of frozen bytes**, after `from_bytes`'s verifier: later.
* **Index types and base-relative links into frozen arrays**: later.
* **Comparing handles**: no; keep a `bool`, or add a named builtin if needed.
* **`sh.view<i64>(m, offset, count)`**: a parser change, on its own merits.
* **Handles as dictionary keys**: no; key by what a handle stands for.
* **Sharing between processes** (`shm_open`): out of scope.
