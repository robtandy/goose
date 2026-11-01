# Measurements for the shared memory design

The programs behind section 11 of
[docs/design/shared_memory.md](../../docs/design/shared_memory.md), kept so
that its numbers can be reproduced on another machine and compared against
by the implementation (#3 and #4). They are small C programs and one Goose
program, not part of the benchmark suite of [design.md](../design.md).

| Program | Measures | Section |
|---|---|---|
| `mapbench.c` | summing a 2 GB `i64` column from the page cache: `pread` into a reused buffer, the whole file read first, and one shared mapping (first and later passes, `MAP_POPULATE`, `MADV_POPULATE_READ`, `MADV_WILLNEED`), on 1 and 16 threads | 11.1 |
| `colfile.c` | writes the column file `mapbench` reads, and drops its pages from the page cache for the cold rows | 11.1 |
| `release.c` | releasing touched 2 GB reservations when 16 threads end together: `munmap`, `MADV_DONTNEED`, or keeping them | 11.2 |
| `mprot.c` | `mprotect(PROT_READ)` of a written region, alone and with 15 threads running | 11.3 |
| `attach.c` | an attach and a detach as an atomic increment and decrement of one counter on 1, 4 and 16 threads | 11.4 |
| `sigbus.c` | the signal a read past the end of a truncated mapping raises, and what its handler can tell | 11.5 |
| `join_loops.goose` | the hash join's three loops (section 8.3) as `checkfree` functions over `const` slices standing in for views | 11.6 |

`run.sh` builds the C programs and runs each three times:

```sh
bench/shared_memory/run.sh /path/to/scratch            # clang; COLD=0 skips the cold-cache rows
goose check -O2 bench/shared_memory/join_loops.goose  # compiles only if every checkfree loop is check-free
goose run bench/shared_memory/join_loops.goose        # 5000 matches, payloads summing to 12497500
```

The scratch directory should be on the file system whose files are to be
mapped (the design's numbers are on the overlay file system the more-fast-db
data lives on) and needs 2 GB free. The C programs are for Linux; `release`,
`mprot`, `attach` and `sigbus` also build on macOS.
