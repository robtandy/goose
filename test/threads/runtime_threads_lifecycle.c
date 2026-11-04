/* Direct runtime regression: bounded resource use under repeated worker
   creation, including workers nobody joins, concurrent/repeated waits and
   contained workers that abort, whose messages the runtime keeps until a
   wait takes them; and under thread pools run phase after phase, across
   programs started and stopped in turn, both the pools a program destroys
   and those it leaves for the stop. Small limits make a region registry
   that leaks entries fail quickly. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

static volatile long live_allocations, live_regions;

static long counter_add(volatile long *p, long n) {
#ifdef _WIN32
    return InterlockedExchangeAdd(p, n);
#else
    return __sync_fetch_and_add(p, n);
#endif
}

static void check(int ok, const char *what) {
    if (!ok) {
        fprintf(stderr, "runtime lifecycle check failed: %s\n", what);
        exit(2);
    }
}

static void *counted_malloc(size_t size) {
    void *p = malloc(size);
    if (p) counter_add(&live_allocations, 1);
    return p;
}

static void *counted_calloc(size_t n, size_t size) {
    void *p = calloc(n, size);
    if (p) counter_add(&live_allocations, 1);
    return p;
}

static void counted_free(void *p) {
    if (p) counter_add(&live_allocations, -1);
    free(p);
}

/* A block made from nothing is one more; a grown one is the same block. */
static void *counted_realloc(void *p, size_t size) {
    void *q = realloc(p, size);
    if (q && !p) counter_add(&live_allocations, 1);
    return q;
}

#ifdef _WIN32
static void *counted_virtual_alloc(void *base, SIZE_T size, DWORD kind, DWORD prot) {
    void *p = VirtualAlloc(base, size, kind, prot);
    if (p && (kind & MEM_RESERVE)) counter_add(&live_regions, 1);
    return p;
}

static BOOL counted_virtual_free(void *base, SIZE_T size, DWORD kind) {
    BOOL ok = VirtualFree(base, size, kind);
    if (ok && kind == MEM_RELEASE) counter_add(&live_regions, -1);
    return ok;
}
#define VirtualAlloc counted_virtual_alloc
#define VirtualFree counted_virtual_free
#else
static void *counted_mmap(void *base, size_t size, int prot, int flags, int fd, off_t off) {
    void *p = mmap(base, size, prot, flags, fd, off);
    if (p != MAP_FAILED) counter_add(&live_regions, 1);
    return p;
}

static int counted_munmap(void *base, size_t size) {
    int result = munmap(base, size);
    if (!result) counter_add(&live_regions, -1);
    return result;
}
#define mmap counted_mmap
#define munmap counted_munmap
#endif

#define malloc counted_malloc
#define calloc counted_calloc
#define free counted_free
#define realloc counted_realloc
#define GS_NEED_THREADS 1
#define GS_MAX_STACKS 8
#define GS_STACK_RESERVE (256u << 10)
#define GS_STACK_GAP (64u << 10)
#include "../../src/runtime/runtime.h"
#include "../../src/runtime/runtime_impl.h"
#include "../../src/runtime/runtime_threads.h"

static gs_mutex test_mutex = GS_MUTEX_INIT;
static gs_cond test_cond = GS_COND_INIT;
static int gate_open, waiters_ready;
static int64_t descendant_id;

static void exercise_stacks(uint8_t *args) {
    int64_t stamp;
    memcpy(&stamp, args, sizeof(stamp));
    check(gs_nregions == 0, "worker starts without old mappings");
    gs_stack_block(GS_MAX_STACKS);
    check(gs_nregions == GS_MAX_STACKS, "worker owns its region registry");
    for (int i = 0; i < GS_MAX_STACKS; ++i) {
        GS(i)->top[0] = (uint8_t)stamp;
        GS(i)->top[GS_STACK_RESERVE - 1] = (uint8_t)(stamp + i);
    }
    for (int i = 0; i < GS_MAX_STACKS; ++i) {
        check(GS(i)->top[0] == (uint8_t)stamp, "concurrent mappings are disjoint");
        check(GS(i)->top[GS_STACK_RESERVE - 1] == (uint8_t)(stamp + i),
              "last usable page is accessible");
    }
}

static void gated_worker(uint8_t *args) {
    exercise_stacks(args);
    gs_mutex_lock(&test_mutex);
    while (!gate_open) gs_cond_wait(&test_cond, &test_mutex);
    gs_mutex_unlock(&test_mutex);
    int64_t stamp;
    memcpy(&stamp, args, sizeof(stamp));
    check(GS(0)->top[0] == (uint8_t)stamp, "other workers' exits preserve this storage");
}

static void spawning_worker(uint8_t *args) {
    exercise_stacks(args);
    int64_t child = gs_thread_spawn(gated_worker, args, sizeof(int64_t), 0);
    gs_mutex_lock(&test_mutex);
    descendant_id = child;
    gs_mutex_unlock(&test_mutex);
}

static void waiting_worker(uint8_t *args) {
    int64_t target;
    memcpy(&target, args, sizeof(target));
    gs_mutex_lock(&test_mutex);
    ++waiters_ready;
    gs_cond_broadcast(&test_cond);
    gs_mutex_unlock(&test_mutex);
    gs_thread_wait(target, NULL, NULL, __FILE__, __LINE__);
    gs_thread_wait(target, NULL, NULL, __FILE__, __LINE__);
}

/* As a thunk does, a globals instance, then an abort past it: the contained
   worker's storage is released as on a return. */
static void aborting_worker(uint8_t *args) {
    exercise_stacks(args);
    gs_gl = calloc(1, 64);
    check(gs_gl != NULL, "allocate a globals instance");
    gs_abort(GS_E_ASSERT, __FILE__, __LINE__);
}

/* An abort raised under the worker registry's lock, which must be free
   again once the worker has ended. */
static void bad_waiting_worker(uint8_t *args) {
    (void)args;
    gs_thread_wait(-1, NULL, NULL, __FILE__, __LINE__);
}

/* Observe exit without calling thread_wait: cleanup must not depend on join. */
static void wait_quiescent(void) {
    gs_mutex_lock(&gs_threads_mutex);
    while (gs_threads) gs_cond_wait(&gs_threads_done, &gs_threads_mutex);
    gs_mutex_unlock(&gs_threads_mutex);
}

static void check_baseline(long allocations, long regions) {
    check(counter_add(&live_allocations, 0) == allocations,
          "all worker records, arguments and stack blocks released");
    check(counter_add(&live_regions, 0) == regions, "all worker reservations released");
    check(gs_nregions == 1 && GS(0)->top[0] == 99, "main storage survives worker exit");
}

/* The pools the runtime lists as live, newest first. */
static int live_pools(void) {
    int n = 0;
    for (struct gs_pool_state *p = gs_live_pools, *before = NULL; p; before = p, p = p->next) {
        check(p->prev == before, "the live pools' list links both ways");
        ++n;
    }
    return n;
}

/* A pool's first phase, one task for each of its workers: each waits until
   all have started, so that every worker runs one and maps its stacks. */
#define POOL_THREADS 3
static int pool_arrived, pool_phases;

static void pool_barrier_task(uint8_t *args) {
    exercise_stacks(args);
    gs_mutex_lock(&test_mutex);
    int phase = pool_phases;
    if (++pool_arrived == POOL_THREADS) {
        pool_arrived = 0;
        ++pool_phases;
        gs_cond_broadcast(&test_cond);
    }
    while (phase == pool_phases) gs_cond_wait(&test_cond, &test_mutex);
    gs_mutex_unlock(&test_mutex);
}

/* Phases as pool.apply runs them: tasks handed to the pool, then waited
   for. The phases after the first, of more tasks than workers, run on the
   stacks it mapped, and leave the pool holding what it held after it. */
static void run_pool(gs_pool pool, int64_t seed) {
    for (int i = 0; i < POOL_THREADS; ++i) {
        int64_t stamp = seed + i;
        gs_pool_spawn(pool, pool_barrier_task, &stamp, sizeof(stamp));
    }
    gs_pool_wait(pool);
    long allocations = counter_add(&live_allocations, 0);
    long regions = counter_add(&live_regions, 0);
    for (int phase = 1; phase < 4; ++phase) {
        for (int i = 0; i < 3 * POOL_THREADS; ++i) {
            int64_t stamp = seed + phase * 3 * POOL_THREADS + i;
            gs_pool_spawn(pool, exercise_stacks, &stamp, sizeof(stamp));
        }
        gs_pool_wait(pool);
        check(counter_add(&live_allocations, 0) == allocations,
              "a pool's tasks release their records, arguments and stack blocks");
        check(counter_add(&live_regions, 0) == regions, "a pool's workers reuse their mappings");
    }
}

#ifndef _WIN32
static int parked;

/* A task that never ends. */
static void parked_task(uint8_t *args) {
    (void)args;
    gs_mutex_lock(&test_mutex);
    parked = 1;
    gs_cond_broadcast(&test_cond);
    for (;;) gs_cond_wait(&test_cond, &test_mutex);
}

/* Stopping while a pool still has a task to finish is the runtime error a
   running worker is, rather than a wait for the task or the pool destroyed
   under it: in a process of its own, which the error ends. An idle pool,
   newer and so listed first, does not hide the busy one. */
static void check_busy_pool_stop(void) {
    int err[2];
    check(!pipe(err), "open a pipe for the stopped program's error");
    fflush(NULL);
    pid_t child = fork();
    check(child >= 0, "fork a program to stop mid-task");
    if (!child) {
        dup2(err[1], STDERR_FILENO);
        close(err[0]);
        close(err[1]);
        alarm(20);  /* a stop that waits for the task never returns */
        gs_rt_init(0, NULL, 1, 1, GS_MAX_STACKS);
        gs_pool busy = gs_pool_create(POOL_THREADS, __FILE__, __LINE__);
        gs_pool_create(1, __FILE__, __LINE__);
        int64_t stamp = 7;
        gs_pool_spawn(busy, parked_task, &stamp, sizeof(stamp));
        gs_mutex_lock(&test_mutex);
        while (!parked) gs_cond_wait(&test_cond, &test_mutex);
        gs_mutex_unlock(&test_mutex);
        gs_thread_release();
        gs_rt_stop();
        _exit(0);
    }
    close(err[1]);
    char text[512];
    size_t n = 0;
    ssize_t got;
    while (n < sizeof(text) - 1 && (got = read(err[0], text + n, sizeof(text) - 1 - n)) > 0)
        n += (size_t)got;
    text[n] = 0;
    close(err[0]);
    int status;
    int refused = waitpid(child, &status, 0) == child && WIFEXITED(status) &&
                  WEXITSTATUS(status) == 1 &&
                  strstr(text, "goose_exit: a thread program is still running");
    if (!refused) fputs(text, stderr);
    check(refused, "stopping while a pool's task runs is a runtime error");
}
#endif

int main(void) {
#ifndef _WIN32
    struct sigaction before;
    check(!sigaction(SIGSEGV, NULL, &before), "read the fault handling the runtime will find");
#endif
    /* Main's one stack, in its one region; a worker's GS_MAX_STACKS. */
    gs_rt_init(0, NULL, 1, 1, GS_MAX_STACKS);
    check(gs_hardware_threads() >= 1, "hardware_threads() reports at least one worker");
    GS(0)->top[0] = 99;
    long allocations = counter_add(&live_allocations, 0);
    long regions = counter_add(&live_regions, 0);
#ifdef _WIN32
    DWORD handles_before, handles_after;
    check(GetProcessHandleCount(GetCurrentProcess(), &handles_before), "read handle count");
#endif
    int64_t oldest = -1, previous = -1;
    for (int round = 0; round < 64; ++round) {
        int64_t ids[8];
        for (int i = 0; i < 8; ++i) {
            int64_t stamp = round * 8 + i;
            ids[i] = gs_thread_spawn(exercise_stacks, &stamp, sizeof(stamp), 0);
            check(ids[i] > previous, "thread IDs are never reused");
            previous = ids[i];
            if (oldest < 0) oldest = ids[i];
        }
        if (round % 2 == 0) {
            for (int i = 7; i >= 0; --i) gs_thread_wait(ids[i], NULL, NULL, __FILE__, __LINE__);
        } else {
            wait_quiescent();
        }
        check_baseline(allocations, regions);
        gs_thread_wait(oldest, NULL, NULL, __FILE__, __LINE__);
    }

    int64_t stamp = 42;
    int64_t parent = gs_thread_spawn(spawning_worker, &stamp, sizeof(stamp), 0);
    gs_thread_wait(parent, NULL, NULL, __FILE__, __LINE__);
    gs_mutex_lock(&test_mutex);
    int64_t child = descendant_id;
    gate_open = 1;
    gs_cond_broadcast(&test_cond);
    gs_mutex_unlock(&test_mutex);
    gs_thread_wait(child, NULL, NULL, __FILE__, __LINE__);
    check_baseline(allocations, regions);
    gate_open = 0;

    int64_t target = gs_thread_spawn(gated_worker, &stamp, sizeof(stamp), 0);
    int64_t waiter_a = gs_thread_spawn(waiting_worker, &target, sizeof(target), 0);
    int64_t waiter_b = gs_thread_spawn(waiting_worker, &target, sizeof(target), 0);
    gs_mutex_lock(&test_mutex);
    while (waiters_ready != 2) gs_cond_wait(&test_cond, &test_mutex);
    gate_open = 1;
    gs_cond_broadcast(&test_cond);
    gs_mutex_unlock(&test_mutex);
    gs_thread_wait(target, NULL, NULL, __FILE__, __LINE__);
    gs_thread_wait(waiter_a, NULL, NULL, __FILE__, __LINE__);
    gs_thread_wait(waiter_b, NULL, NULL, __FILE__, __LINE__);
    check_baseline(allocations, regions);

    for (int round = 0; round < 16; ++round) {
        int64_t ids[8];
        for (int i = 0; i < 8; ++i) {
            int64_t seed = round * 8 + i;
            ids[i] = gs_thread_spawn(i % 4 == 3 ? exercise_stacks : aborting_worker, &seed,
                                     sizeof(seed), 1);
        }
        if (round % 2 == 0) wait_quiescent();
        for (int i = 0; i < 8; ++i) {
            check(gs_thread_wait(ids[i], NULL, NULL, __FILE__, __LINE__) == (i % 4 == 3),
                  "thread_wait tells an aborted contained worker from a returned one");
            uint8_t *msg;
            int64_t len;
            static const char want[] = "assert failed (";
            check(gs_thread_wait(ids[i], &msg, &len, __FILE__, __LINE__) == (i % 4 == 3),
                  "a repeated wait gives the same answer");
            check(i % 4 == 3 ? !msg && len == 0
                             : msg && len > (int64_t)sizeof want &&
                               !memcmp(msg, want, sizeof want - 1) && msg[len - 1] == ')',
                  "the first wait to ask takes the abort's message, and a return has none");
            gs_free_msg(msg);
            check(gs_thread_wait(ids[i], &msg, &len, __FILE__, __LINE__) == (i % 4 == 3) &&
                  !msg && len == 0, "a later wait still answers, but gets no message");
        }
        /* The two records of which workers aborted (gs_aborted_add) stay
           for the program's lifetime. */
        check_baseline(allocations + 2, regions);
    }
    /* A message no wait takes stays until the program ends. */
    int64_t bad = gs_thread_spawn(bad_waiting_worker, &stamp, sizeof(stamp), 1);
    check(!gs_thread_wait(bad, NULL, NULL, __FILE__, __LINE__), "a contained worker aborts in thread_wait");
    check(gs_thread_wait(target, NULL, NULL, __FILE__, __LINE__), "a plain worker that returned waits true");
    check_baseline(allocations + 3, regions);
#ifdef _WIN32
    check(GetProcessHandleCount(GetCurrentProcess(), &handles_after), "read handle count");
    check(handles_after == handles_before, "native thread handles released");
#endif
    /* The main program's end (goose_exit): its stack block and globals
       instance (main has none here) as a worker's end releases them, then
       gs_rt_stop, which takes the aborted workers' records (the message
       above among them), main's regions and the fault handling, so that a
       program can start again in the process and end as cleanly. */
    gs_thread_release();
    gs_rt_stop();
    check(counter_add(&live_allocations, 0) == 0,
          "stopping releases main's stack block and the abort records");
    check(counter_add(&live_regions, 0) == 0, "stopping releases main's reservation");
#ifndef _WIN32
    struct sigaction after;
    check(!sigaction(SIGSEGV, NULL, &after) && after.sa_sigaction == before.sa_sigaction,
          "stopping restores the fault handling the runtime found");
#endif
    gs_rt_init(0, NULL, 1, 1, GS_MAX_STACKS);
    check(gs_nregions == 1, "a program starts again after a stop");
    GS(0)->top[0] = 99;
    allocations = counter_add(&live_allocations, 0);
    regions = counter_add(&live_regions, 0);
    int64_t again = gs_thread_spawn(aborting_worker, &stamp, sizeof(stamp), 1);
    check(!gs_thread_wait(again, NULL, NULL, __FILE__, __LINE__),
          "a worker of the program started again runs, and its abort is recorded");
    check_baseline(allocations + 3, regions);
    gs_thread_release();
    gs_rt_stop();
    check(counter_add(&live_allocations, 0) == 0 && counter_add(&live_regions, 0) == 0,
          "the program started again ends as cleanly");

    /* Pools over programs started and stopped in turn, each pool run
       through its phases. The program destroys one, as a local's scope exit
       does: the oldest, the middle or the newest of those live. The stop
       destroys those it leaves, as it leaves a global's, joining their
       workers and releasing their stacks; among them one made just before
       it, whose workers may not have started. */
    for (int cycle = 0; cycle < 3; ++cycle) {
        gs_rt_init(0, NULL, 1, 1, GS_MAX_STACKS);
        GS(0)->top[0] = 99;
        allocations = counter_add(&live_allocations, 0);
        regions = counter_add(&live_regions, 0);
        gs_pool pools[3];
        long held_allocations[3], held_regions[3];
        long all_allocations = 0, all_regions = 0;
        for (int k = 0; k < 3; ++k) {
            long a = counter_add(&live_allocations, 0), m = counter_add(&live_regions, 0);
            pools[k] = gs_pool_create(POOL_THREADS, __FILE__, __LINE__);
            run_pool(pools[k], cycle * 64 + k * 16);
            held_allocations[k] = counter_add(&live_allocations, 0) - a;
            held_regions[k] = counter_add(&live_regions, 0) - m;
            check(held_regions[k] == POOL_THREADS * GS_MAX_STACKS,
                  "each worker of a pool keeps its stacks mapped between tasks");
            check(live_pools() == k + 1 && gs_live_pools == pools[k], "a pool made is live");
            all_allocations += held_allocations[k];
            all_regions += held_regions[k];
        }
        gs_pool_destroy(pools[cycle]);
        check(live_pools() == 2, "a pool destroyed is not live");
        check_baseline(allocations + all_allocations - held_allocations[cycle],
                       regions + all_regions - held_regions[cycle]);
        gs_pool_create(POOL_THREADS, __FILE__, __LINE__);
        gs_thread_release();
        gs_rt_stop();
        check(!gs_live_pools, "stopping destroys the pools left");
        check(counter_add(&live_allocations, 0) == 0,
              "stopping releases the pools' records and their workers' registries");
        check(counter_add(&live_regions, 0) == 0, "stopping releases the pools' worker stacks");
    }
#ifndef _WIN32
    check_busy_pool_stop();
#endif
    puts("runtime thread cleanup ok");
    return 0;
}
