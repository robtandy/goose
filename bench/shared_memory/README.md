# Measurements for the shared memory design

The programs behind the numbers in
[docs/design/shared_memory.md](../../docs/design/shared_memory.md), kept so
that they can be reproduced on another machine and compared against by the
implementation (#3 and #4). They are small C programs and one Goose program,
not part of the benchmark suite of [design.md](../design.md).

| Program | Measures | Used in the note |
|---|---|---|
| `mapbench.c` | summing a 2 GB `i64` column from the page cache: `pread` into a reused buffer, the whole file read first, and one shared mapping (first and later passes, `MAP_POPULATE`, `MADV_POPULATE_READ`, `MADV_WILLNEED`), on 1 and 16 threads | sections 2 and 5.3 |
| `colfile.c` | writes the column file `mapbench` reads, and drops its pages from the page cache for the cold rows | |
| `release.c` | releasing touched 2 GB reservations when 16 threads end together: `munmap`, `MADV_DONTNEED`, or keeping them | 5.2 |
| `mprot.c` | `mprotect(PROT_READ)` of a written region, alone and with 15 threads running | 4.6 |
| `attach.c` | an attach and a detach as an atomic increment and decrement of one counter on 1, 4 and 16 threads | 4.6 |
| `sigbus.c` | the signal a read past the end of a truncated mapping raises, and what its handler can tell | 5.3 |
| `join_loops.goose` | the hash join's three loops as `checkfree` functions over `const` slices standing in for views | 4.5 and 6 |

`run.sh` builds the C programs and runs each three times:

```sh
bench/shared_memory/run.sh /path/to/scratch            # clang; COLD=0 skips the cold-cache rows
goose check -O2 bench/shared_memory/join_loops.goose  # compiles only if every checkfree loop is check-free
goose run bench/shared_memory/join_loops.goose        # 5000 matches, payloads summing to 12497500
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
