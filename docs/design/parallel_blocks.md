# Reusable thread pools and `pool.apply(chunks(...), fn, args...)`

Status: implemented on `feat/parallel-scope`.

<details>
<summary>Table of contents</summary>

- [1. Motivation](#1-motivation)
- [2. Prior art and what is new in Goose](#2-prior-art-and-what-is-new-in-goose)
- [3. Syntax and constructs](#3-syntax-and-constructs)
- [4. Compile-time safety and data-race freedom](#4-compile-time-safety-and-data-race-freedom)
- [5. Runtime and Data Stack reuse](#5-runtime-and-data-stack-reuse)
- [6. Worked examples (including parallel Hash Join)](#6-worked-examples-including-parallel-hash-join)

</details>

## 1. Motivation

Goose's existing concurrency model (§11.2, `thread_fn` + `thread_spawn` / `thread_wait` + typed queues `qput` / `qget`) is designed for **unstructured, isolated actor threads**:
- A `thread_fn` spawned with `thread_spawn` may outlive the scope that spawned it and runs concurrently with the parent thread.
- Because its lifetime is unbounded relative to the caller's scopes, a `thread_fn` may only accept **flat, by-value copies** of its arguments and globals (`memcpy`), cannot be called as an ordinary function, and can only return results by copying flat byte images into a process-wide `qput<T>` queue.
- Each `thread_spawn` creates a fresh OS thread (`pthread_create` / `_beginthreadex`), reserves a fresh block of 2 GB virtual-memory Data Stacks (`mmap` / `VirtualAlloc`), and tears both down (`munmap` / `VirtualFree`) when the worker exits.

For structured data-parallel workloads (such as image rendering, matrix/tensor kernels, simulation steps, or database joins and filters across consecutive passes), unstructured `thread_spawn` has three costs:
1. **Thread & `mmap` churn**: Spinning up OS threads and mapping/unmapping multi-gigabyte Data Stack regions on every parallel phase costs puluhan of microseconds per phase.
2. **Input copying**: Large lookup tables, hash tables, or scene graphs cannot be read in place by workers; they must be serialized into each worker's spawn packet.
3. **Output copying**: Workers cannot write directly into disjoint slices of an output array; they must build local arrays, `qput` them into a queue, and have the main thread `qget` and copy them into the destination array (as in `samples/23_mandelbrot_threads.goose`).

**`thread_pool` + `pool.apply(chunks(...), fn, args...)`** solves all three while leaving `thread_fn` 100% untouched for isolated actor threads.

---

## 2. Prior art and what is new in Goose

### Prior art in scope-bounded parallelism

| System / Language | Construct | How it handles memory & safety |
|---|---|---|
| **Cilk** (1994) / **OpenMP** (1997) | `cilk_for` / `#pragma omp parallel for` | Tasks can point into the parent's C stack frame because the parallel loop joins before continuing. No static check against data races. |
| **Rust** (`std::thread::scope` + Rayon `par_chunks_mut`) | `slice.par_chunks_mut(k).for_each(...)` | Statically proves tasks cannot outlive the call and uses `&T` (shared read-only) + `chunks_mut` (disjoint `&mut [T]`) for data-race freedom. |

### What is genuinely new in Goose's design

1. **One-line synchronous barrier (`pool.apply(chunks(...), fn, args...)`) with zero lifetime annotations**:
   Because `pool.apply` is a single synchronous call that dispatches all chunks of the target array and waits for them to complete before returning:
   - The calling thread is blocked inside `pool.apply`, so it **cannot** mutate or shrink the target array or any shared `const` arguments while workers are running.
   - Every variable in the caller's scope automatically outlives all worker tasks.
   - The compiler only needs to check one aliasing invariant at the call site: **no shared `const` argument (or `offsets` slice) may share a root with the partitioned output array**.
2. **Ordinary `fn`s (leaving `thread_fn` untouched)**:
   Workers dispatched by `pool.apply` are regular top-level `fn`s—not `thread_fn`s. The exact same `fn` can be called directly on a single thread (for debugging, tests, or small inputs) or dispatched across worker threads via `pool.apply`.
3. **Both uniform (`chunks(arr, size)`) and prefix-sum (`chunks(arr, offsets)`) disjoint partitioning**:
   Supporting a monotonically increasing `offsets: const i64[:]` slice alongside a uniform `size: i64` allows variable-output parallel algorithms (such as a two-pass database **Hash Join** or parallel `filter`) to write directly into exact disjoint slices `arr[offsets[idx] .. offsets[idx + 1]]` of a single contiguous output array.
4. **Pre-reserved virtual-memory Data Stacks per pool worker with $O(1)$ rewind**:
   Each worker thread in a `thread_pool` maps its 2 GB virtual-memory Data Stacks **once** when the pool is created. When a worker's `fn` allocates temporary growable arrays (`u8[>..]`, `i64[>..]`) and returns, the worker resets `gs_nregions = 0` so the next chunk reuses the exact same `mmap` base pointers (`gs_regions[i].base`) in $O(1)$—**zero heap allocations and zero `mmap`/`munmap` syscalls across consecutive `pool.apply` calls**.

---

## 3. Syntax and constructs

### 3.1 Declaring a reusable thread pool: `thread_pool`

```goose
var pool = thread_pool(4);                  // explicit worker thread count
var default_pool = thread_pool();           // defaults to hardware_threads()
```

- `thread_pool` is a built-in resource type (`TY_POOL`) representing a pool of persistent OS worker threads, each owning a reusable block of Data Stacks.
- A `thread_pool` variable may be declared as a local or a global, and may be borrowed by reference (`p: thread_pool&`) to pass into helper functions.
- A `thread_pool` cannot be copied by value, reassigned, serialized, or sent through a queue.
- The program ends a pool itself, with `pool.close()` (or `close(pool)`), usually under `defer` right after making it:

  ```goose
  var pool = thread_pool(4);
  defer pool.close();
  ```

  `close` wakes the pool's worker threads, joins them, and releases their Data Stack regions. The variable then holds a closed pool: closing it again does nothing, and `pool.apply(...)` on it aborts with `cannot apply on a closed thread_pool`. `close` takes the pool's variable (`let` or `var`, local or global) or a reference to it through which it can be written; a `const thread_pool&` applies a pool but cannot close it.
- Nothing ends a pool at its scope's exit, since no code runs at a scope exit that the programmer did not write ([ownership.md](ownership.md)). A pool the program leaves open lives until the process exits, which takes its threads and their mappings with it at once. That is cheaper than destroying the pool: all its workers unmap their Data Stacks at the same moment, which the kernel serializes (1 to 2 ms per worker that touched about 14 MB, measured on 16 threads on aarch64 Linux). A library's `goose_exit` destroys the pools its program leaves open, so that a host can start the program again.

### 3.2 Applying a function across disjoint mutable chunks: `pool.apply`

```goose
// Uniform chunk size:
pool.apply(chunks(data, chunk_size), worker_fn, extra_args...);

// Variable chunk sizes from a prefix-sum offsets array/slice:
pool.apply(chunks(data, offsets), worker_fn, extra_args...);
```

- `data` must be a writable indexable array (`T[k]`, `T[..k]`, `T[..]`, `T[>..]`, `T[>..<]`) or writable slice (`T[:]`) whose element type `T` is fixed-size (`SC_FIXED`) and `flat` (`IsFlat(T)`), with a single known exact root.
- The second argument to `chunks(data, ...)` is either:
  - **`chunk_size: i64`**: splits `data` into $\lceil \text{data.len} / \text{chunk\_size} \rceil$ contiguous slices of up to `chunk_size` elements (aborting if `chunk_size <= 0`).
  - **`offsets: const i64[:]`**: splits `data` into `offsets.len - 1` contiguous slices `data[offsets[idx] .. offsets[idx + 1]]`, verifying at runtime that `0 <= offsets[0] <= offsets[1] <= ... <= data.len` (aborting with `GS_E_CHUNKBOUNDS` before spawning if any pair is out of bounds or not monotonically non-decreasing).
- `worker_fn` is a regular top-level `fn` with no return value whose signature is either:
  - `fn worker_fn(chunk: T[:], extra_0, ..., extra_{K-1})` (without chunk index), or
  - `fn worker_fn(chunk: T[:], idx: i64, extra_0, ..., extra_{K-1})` (with 0-based chunk index `idx: i64`).
- Each extra parameter `extra_j` of `worker_fn` may be:
  1. **A flat by-value type (`IsFlat(U)`)**: scalars, flat structs, flat arrays, etc.
  2. **A read-only shared slice or reference (`const U[:]` or `const U&`)** where `U` is fixed-size and `flat` (`IsFlat(U)`), passed by pointer/slice header with **zero copying**.

---

## 4. Compile-time safety and data-race freedom

The typechecker (`src/typecheck_calls.h`, `src/typecheck_builtins.h`) enforces four invariants on `pool.apply(chunks(data, spec), worker_fn, extra_args...)`:

1. **Disjointness of mutable chunks**:
   - For `chunks(data, size)`, `off` steps by `size > 0`, so chunks `[0..size)`, `[size..2*size)`, ... are disjoint by construction.
   - For `chunks(data, offsets)`, the inductive runtime check `0 <= offsets[idx] <= offsets[idx + 1] <= data.len` guarantees all slices `[offsets[idx] .. offsets[idx + 1])` are disjoint and in bounds.
2. **No aliasing between `data` and shared `const` arguments (or `offsets`)**:
   - The compiler checks that `data` has a single exact root `data_root`, and rejects `pool.apply` at compile time if `offsets` or any reference/slice extra argument `av` can alias `data_root` (`av.Has(data_root)`).
3. **Deep immutability of shared `const` arguments**:
   - Extra reference/slice parameters of `worker_fn` must be `const U&` or `const U[:]` with `IsFlat(U)` (`ra.writable = false`). Any attempt inside `worker_fn` (or its callees) to mutate through a `const` parameter is rejected at compile time.
4. **No reference escape**:
   - Because `T` (the chunk element type) and `U` (any shared `const` pointee type) are `flat`, a worker cannot store a reference to worker-local Data Stack memory into `chunk`, and `EnsurePoolSpec` assigns parameter root classes local depth `pdepth >= 1` so parameter references cannot be stored into globals (`depth == 0`).

---

## 5. Runtime and Data Stack reuse

In `src/runtime/runtime.h`, `src/runtime/runtime_impl.h`, and `src/runtime/runtime_threads.h`:

- **`gs_pool_create(nthreads, file, line)`**:
  Spawns `nthreads` persistent OS threads (`pthread_create` on POSIX, `_beginthreadex` on Windows). Each worker thread initializes its fault/region tracking once (`gs_regions_begin(gs_workerregions)`, `gs_native_stack_init()`).
- **Idempotent Data Stack reuse (`gs_regions_mapped`)**:
  Each worker thread keeps `gs_regions_mapped` (the high-water mark of mapped 2 GB Data Stack regions in `gs_regions`). Before each task, `gs_pool_worker_main` resets `gs_nregions = 0`, so every `gs_reserve_region` call inside the task's thunk returns the already-mapped `gs_regions[i].base` in $O(1)$ without calling `mmap` or `munmap`.
- **`gs_pool_submit` and `gs_pool_wait`**:
  `EmitPoolApply` dispatches all chunks via `gs_pool_submit` and calls `gs_pool_wait(pool)` before returning.
- **`gs_pool_destroy` and `gs_pool_check_open`**:
  `pool.close()` emits `gs_pool_destroy(pool)`, which joins all worker threads and unmaps their Data Stack regions, and then sets the variable to `NULL`, the closed pool, which `gs_pool_destroy` leaves alone. `pool.apply` first calls `gs_pool_check_open(pool, file, line)`, which aborts with `GS_E_POOLCLOSED` on a closed pool. No scope exit emits either; `gs_rt_stop` (a library's `goose_exit`) destroys the pools a program leaves open.

---

## 6. Worked examples (including parallel Hash Join)

### 6.1 Smallest example: two-pass parallel transform

```goose
fn scale_chunk(chunk: i64[:], weights: const i64[:], bias: i64) {
    for &x, i in chunk {
        x = x * weights[i % weights.len] + bias;
    }
}

fn main() {
    var pool = thread_pool(4);
    defer pool.close();
    let weights = [10, 20];
    var data: i64[>..] = [1, 2, 3, 4, 5, 6];

    pool.apply(chunks(data, 2), scale_chunk, weights, 1);
    print("pass 1: ", data);   // [11, 41, 31, 81, 51, 121]

    pool.apply(chunks(data, 3), scale_chunk, weights, 0);
    print("pass 2: ", data);   // [110, 820, 310, 810, 1020, 1210]
}
```

### 6.2 Parallel Database Hash Join (`chunks(counts, 1)` + `chunks(joined, offsets)`)

See [`test/threads/parallel_scope.goose`](../../test/threads/parallel_scope.goose) for a complete runnable two-pass parallel Hash Join:

```goose
// Pass 1: Each worker counts matches for its probe morsel `[idx * step .. (idx + 1) * step]`
pool.apply(chunks(counts, 1), count_join_matches, ht, probe, step);

// Main thread computes prefix-sum offsets and resizes `joined` once:
var offsets: i64[>..] = [0];
for c in counts { offsets.push(offsets[offsets.len - 1] + c); }
var joined: JoinedRow[>..] = [];
joined.resize(offsets[offsets.len - 1], default<JoinedRow>());

// Pass 2: Each worker writes its matches directly into `joined[offsets[idx] .. offsets[idx + 1]]`!
pool.apply(chunks(joined, offsets), write_join_matches, ht, probe, step);
```
