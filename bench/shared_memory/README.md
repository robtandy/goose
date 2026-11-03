# Measurements for the shared memory design

The programs behind the numbers in
[docs/design/shared_memory.md](../../docs/design/shared_memory.md), kept so
that they can be reproduced on another machine and compared against by the
implementation (#3 and #4), whose own measurement, `colsum.goose`, is here
too. They are small C programs and two Goose programs, not part of the
benchmark suite of [design.md](../design.md).

| Program | Measures | Used in the note |
|---|---|---|
| `mapbench.c` | summing a 2 GB `i64` column from the page cache: `pread` into a reused buffer, the whole file read first, and one shared mapping (first and later passes, `MAP_POPULATE`, `MADV_POPULATE_READ`, `MADV_WILLNEED`), on 1 and 16 threads | sections 2 and 5.3 |
| `colfile.c` | writes the column file `mapbench` reads, and drops its pages from the page cache for the cold rows | |
| `release.c` | releasing touched 2 GB reservations when 16 threads end together: `munmap`, `MADV_DONTNEED`, or keeping them | 5.2 |
| `mprot.c` | `mprotect(PROT_READ)` of a written region, alone and with 15 threads running | 4.6 |
| `attach.c` | an attach and a detach as an atomic increment and decrement of one counter on 1, 4 and 16 threads | 4.6 |
| `sigbus.c` | the signal a read past the end of a truncated mapping raises, and what its handler can tell | 5.3 |
| `join_loops.goose` | the hash join's three loops as `checkfree` functions over `const` slices standing in for views | 4.5 and 6 |
| `colsum.goose` | the 2 GB sum in Goose, as phase 1 built it: through views of one mapping, by `pread` into a reused buffer (`colsum_impl.c`, an `extern fn`, from its sidecar `colsum.build`), and from the whole file read with `read_file` | 2 and 12 |
| `join.goose` | section 6's join as phase 2 built it, on frozen regions: W workers partition onto dynamic stacks and freeze, build tables chained by self-relative links and freeze them, and probe every table in place; or, for comparison, probe private copies of the tables, sent to every worker through a queue | 12 |

`run.sh` builds the C programs and `colsum.goose`, and runs each three times:

```sh
bench/shared_memory/run.sh /path/to/scratch            # clang; COLD=0 skips the cold-cache rows
goose check -O2 bench/shared_memory/join_loops.goose  # compiles only if every checkfree loop is check-free
goose run bench/shared_memory/join_loops.goose        # 5000 matches, payloads summing to 12497500
goose build -O2 --cc clang -o colsum bench/shared_memory/colsum.goose
./colsum /path/to/scratch/col.i64 view 16 2           # view, pread or read_file; threads; passes
goose build -O2 --cc clang -o join bench/shared_memory/join.goose
./join frozen 16 64 16000000 64000000                 # frozen or copies; W, P, build rows, probe rows
```

The scratch directory should be on the file system whose files are to be
mapped, and needs 2 GB free. The C programs are for Linux; `release`, `mprot`,
`attach` and `sigbus` also build on macOS.

## Results

Linux 7.0 on aarch64 (Neoverse N1, 16 cores, 64 GB, 4 KB pages), clang -O2,
the scratch directory on an overlay file system, the file warm in the page
cache unless stated. Medians of three runs.

### Scanning a file: copies against a mapping

Summing a 2 GB file of 2^28 `i64`s in morsels of 983,040 bytes (122,880
`i64`s), which the threads take from an atomic counter, as they would from a
morsel queue (`mapbench`):

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

A fault maps 16 cached pages at once (the kernel's fault-around), which is why
the first pass costs so little, while a copy moves every byte twice: `pread` is
1.7x to 2.2x slower than the mapping. `MAP_POPULATE` populated the 2 GB in
55 ms on one thread, more than a whole first pass on 16 threads takes (15 ms),
and `MADV_WILLNEED` made no difference with the file cached. Unmapping the 2 GB
mapping after a pass took 15 ms. The cold rows are one run each, and are bound
by the volume. Not measured: each worker mapping the file itself, which on
repeated passes would fault every worker's page tables again.

Copies also cost memory. A table that every worker probes reaches each worker
as a copy: for a hash join with a 16M-row build side, about 770 MB of tables,
16 workers would hold 12 GB.

### The same sum in Goose

`colsum.goose` sums the same file as phase 1 built shared memory (#3):
workers given the arena's and the mapping's handles attach, take morsels
of 983,040 bytes from a queue and sum views of them in a `checkfree`
function; by `pread`, each worker reads its morsels into a buffer it
reuses (`col_pread`, an `extern fn`); `read_file` reads the whole file
into main's memory, which one thread sums and 16 threads get copies of
their parts of, as spawn arguments, since a thread's memory reaches
another only as a copy. Built with `goose build -O2 --cc clang`, each run
next to `mapbench`'s of the same method, medians of three:

| Method | 1 thread | 16 threads | `mapbench`, 1 and 16 |
|---|---:|---:|---:|
| `pread` into a reused buffer | 9.3 GB/s | 74 GB/s | 9.3, 76 GB/s |
| `read_file`, then summed | 1.85 GB/s | 0.9 GB/s | 2.24, 2.44 GB/s |
| views of one mapping, first pass, the mapping made in it | 15.5 GB/s | 137 GB/s | 15.2, 142 GB/s |
| the same views, later passes | 20.1 GB/s | 157 GB/s | 20.0, 165 GB/s |

On one thread the views are the C mapping, and on 16 within 3 to 5%,
taking morsels from a locked queue where `mapbench` has an atomic counter.
They are 1.7x (first pass) to 2.2x faster than `pread`, which copies every
byte twice. A loop over a view is the C a loop over any slice is, plain
loads, which the C compiler vectorizes. `read_file` spends 1.05 s of its
1.16 s reading, through a 64 KB buffer into a data stack (`mapbench`'s
read is 0.86 s), and on 16 threads the copies to the workers cost more
than summing in parallel saves.

### The join on frozen regions

`join.goose`, built with `goose build -O2 --cc clang`, at W = 16 and P = 64:
a build side of 16M (`i64` key, `i64` payload) rows with unique keys and a
probe side of 64M keys, a quarter of which match, both generated by main and
frozen as columns. The tables hold 32.8M entries (the rows and a power of two
of chain heads per partition), 655 MB. In `copies`, each builder puts its
table to main with its chains as indices, main gathers them into one message
and puts it once for each worker, and each worker links its copy again in an
array of its own and probes it with the same loop; in both, every worker
starts probing at once. Medians of three runs on a machine with other work
going on (load average about 5):

| | build: phases 1 and 2 | probe | copy-in | tables held | peak resident |
|---|---:|---:|---:|---:|---:|
| frozen tables, probed in place | 67 ms, 238M rows/s | 480 ms, 133M rows/s | none | 655 MB, once | 1.67 GB |
| a private copy per worker, through a queue | 95 ms, 168M rows/s | 602 ms, 106M rows/s | 6.5 s | 10.5 GB, 16 copies | 23.0 GB |

The probe does no work per element beyond the bucket's `%` and the chain's
links, each an addition (`probe` is `checkfree`). With every worker probing
its own copy at once, the copies' probe is 25% slower and more variable (444
to 625 ms), sixteen 655 MB tables competing for the caches and memory where
one is shared; copying them in takes ten times as long as that probe,
mostly main's sixteen puts of the 655 MB message, one after another, which a
queue copies and a worker copies out again, and costs 14 times the memory.
Phase 1 partitions the 16M rows in 17 ms and phase 2 builds the 64 tables
in 50, with the frozen partitions read in place by every builder.

A slot past its first 2 MB asks for transparent huge pages (`MADV_HUGEPAGE`),
as this kernel gives them only to memory that asks: with them, the probe took
462 ms and without them 560, interleaved runs of the same build.

### Releasing memory when threads end together

Each thread reserves 2 GB regions as the runtime reserves a data stack,
touches 64 MB, and all release at the same moment (`release`):

| Release | 16 threads at once | 1 thread |
|---|---:|---:|
| `munmap` | 80 ms | 4.8 ms |
| `madvise(MADV_DONTNEED)` | 30 ms | 4.7 ms |
| kept for reuse | 0.03 ms | 0.00 ms |

Four 16 MB regions per thread instead of one 64 MB region give the same times
(82 and 29 ms). Releases serialize in the kernel, so the cost grows with the
number of threads releasing at once, not with the memory per thread; this is
why released regions are recycled and `trim_memory()` returns their pages.

### Making a region read-only

`mprotect(PROT_READ)` of a region whose pages are all written (`mprot`): 48 µs
for 4 MB and 1.1 ms for 64 MB with no other thread running; 53 µs and 1.4 ms
with 15 threads running, which the system must make drop their cached
translations. So protecting frozen regions is a debug-build check.

### The attachment count

An attach and a detach, as an atomic increment and decrement of one counter
that every thread uses (`attach`): 11 ns per pair on one thread, 148 ns on
four, 1.0 µs on 16. Once per worker or per phase it is nothing; per morsel
(milliseconds of work) it is under 0.1%; per chunk or per view it would show,
which is why views change no count.

### Truncation

A file mapped `PROT_READ, MAP_SHARED`, truncated through another descriptor
(as another process would), then read past its new end (`sigbus`): the read
raises SIGBUS with `si_code` `BUS_ADRERR` and the faulting address, from which
the handler finds the mapping and the offset (here 8192). Reads inside the new
size succeed.

### `checkfree` over views

A view is a `const` slice, so whether loops over views are check-free can be
tested now, with `const` slices standing in for views. `join_loops.goose` holds
the three loops of the note's hash join (scattering two views of one morsel,
building chains of self-relative links, probing them through tables cut to
their heads) as `checkfree` functions. It compiles with today's compiler at
`-O0`, `-O1` and `-O2`, and matches a reference sum. One gap turned up: the
analysis proves `xs[h % xs.len]` for a hash bound to a local, `let h =
mix(k);`, and also for `(k * 31) % xs.len` written in place, but not for
`xs[mix(k) % xs.len]` with the inlined call in place at `-O1` and above. The
program binds the hash first; the gap belongs with TODO 0f.
