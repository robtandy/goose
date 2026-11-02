/* What this machine allows a queue: the costs a queue is built from,
   measured without one. docs/design/inboxes_select.md sets the targets of
   the queue work against these, beside today's queues (bench/goose/
   queues.goose); bench/queues.py --floor builds and runs this. Linux only
   (futex).

     cc -O2 -pthread bench/queues_floor.c -o queues_floor && ./queues_floor

   Each line is name=value fields, times in nanoseconds:

     atomic  threads=N op=faa|cas   N threads incrementing one shared counter,
                                    with fetch_add or a compare-exchange loop:
                                    ns per increment over all of them
     handoff                        two threads passing a turn through a shared
                                    word, spinning: ns per round trip, the
                                    floor of a message between two cores
     futex                          the same, each side sleeping in futex_wait
                                    until the other's futex_wake: ns per round
                                    trip, two wake-ups
     malloc  size=S where=local|remote   malloc and free of S bytes on one
                                    thread, or malloc on one and free on another
                                    (handed over through a ring): ns per block
     memcpy  size=32768 from=cache|memory   one copy of 32 KB, from a buffer in
                                    cache or streamed from memory: ns per copy */
#define _GNU_SOURCE
#include <linux/futex.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void pause_cpu(void) {
#if defined(__aarch64__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__)
    __builtin_ia32_pause();
#endif
}

/* --- one contended counter ------------------------------------------------ */

static _Alignas(128) atomic_int_fast64_t counter;
static atomic_int ready, go;
static int64_t per_thread;
static int use_cas;

static void *bump(void *arg) {
    (void)arg;
    atomic_fetch_add(&ready, 1);
    while (!atomic_load(&go)) pause_cpu();
    for (int64_t i = 0; i < per_thread; i++) {
        if (use_cas) {
            int_fast64_t v = atomic_load_explicit(&counter, memory_order_relaxed);
            while (!atomic_compare_exchange_weak(&counter, &v, v + 1)) {}
        } else {
            atomic_fetch_add(&counter, 1);
        }
    }
    return NULL;
}

static void contended(int threads, int cas, int64_t total) {
    pthread_t t[64];
    per_thread = total / threads;
    use_cas = cas;
    atomic_store(&counter, 0);
    atomic_store(&ready, 0);
    atomic_store(&go, 0);
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, bump, NULL);
    while (atomic_load(&ready) < threads) pause_cpu();
    int64_t start = now_ns();
    atomic_store(&go, 1);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    int64_t took = now_ns() - start;
    int64_t n = per_thread * threads;
    if (atomic_load(&counter) != n) {
        fprintf(stderr, "queues_floor: lost increments\n");
        exit(1);
    }
    printf("mode=atomic threads=%d op=%s ns_per_op=%.1f\n", threads, cas ? "cas" : "faa",
           (double)took / (double)n);
}

/* --- a turn passed between two threads ------------------------------------- */

static _Alignas(128) atomic_uint turn;
static int64_t rounds;
static int sleeping;

static long futex(atomic_uint *addr, int op, unsigned val) {
    return syscall(SYS_futex, addr, op, val, NULL, NULL, 0);
}

/* Waits until turn holds `want`. */
static void await_turn(unsigned want) {
    for (;;) {
        unsigned v = atomic_load(&turn);
        if (v == want) return;
        if (sleeping) futex(&turn, FUTEX_WAIT_PRIVATE, v);
        else pause_cpu();
    }
}

static void give_turn(unsigned v) {
    atomic_store(&turn, v);
    if (sleeping) futex(&turn, FUTEX_WAKE_PRIVATE, 1);
}

static void *answer(void *arg) {
    (void)arg;
    for (int64_t i = 0; i < rounds; i++) {
        await_turn(1);
        give_turn(0);
    }
    return NULL;
}

static void ping_pong(int sleep, int64_t n) {
    pthread_t t;
    sleeping = sleep;
    rounds = n;
    atomic_store(&turn, 0);
    pthread_create(&t, NULL, answer, NULL);
    int64_t start = now_ns();
    for (int64_t i = 0; i < n; i++) {
        give_turn(1);
        await_turn(0);
    }
    int64_t took = now_ns() - start;
    pthread_join(t, NULL);
    printf("mode=%s ns_per_round_trip=%.1f\n", sleep ? "futex" : "handoff", (double)took / (double)n);
}

/* --- malloc and free --------------------------------------------------------- */

#define RING 1024
static void *_Atomic ring[RING];
static size_t block;
static int64_t blocks;

static void *free_them(void *arg) {
    (void)arg;
    for (int64_t i = 0; i < blocks; i++) {
        void *p;
        while (!(p = atomic_load_explicit(&ring[i % RING], memory_order_acquire))) pause_cpu();
        atomic_store_explicit(&ring[i % RING], NULL, memory_order_relaxed);
        free(p);
    }
    return NULL;
}

static void allocate(size_t size, int remote, int64_t n) {
    block = size;
    blocks = n;
    int64_t start, took;
    if (!remote) {
        start = now_ns();
        for (int64_t i = 0; i < n; i++) {
            char *p = malloc(size);
            if (!p) exit(1);
            p[0] = (char)i;   /* touch it, as a queue's copy would */
            p[size - 1] = (char)i;
            __asm__ __volatile__("" : : "r"(p) : "memory");
            free(p);
        }
        took = now_ns() - start;
    } else {
        pthread_t t;
        memset((void *)ring, 0, sizeof ring);
        pthread_create(&t, NULL, free_them, NULL);
        start = now_ns();
        for (int64_t i = 0; i < n; i++) {
            char *p = malloc(size);
            if (!p) exit(1);
            p[0] = (char)i;
            p[size - 1] = (char)i;
            while (atomic_load_explicit(&ring[i % RING], memory_order_relaxed)) pause_cpu();
            atomic_store_explicit(&ring[i % RING], p, memory_order_release);
        }
        pthread_join(t, NULL);
        took = now_ns() - start;
    }
    printf("mode=malloc size=%zu where=%s ns_per_block=%.1f\n", size, remote ? "remote" : "local",
           (double)took / (double)n);
}

/* --- memcpy ------------------------------------------------------------------- */

static void copies(int from_memory, int64_t n) {
    size_t size = 32768, span = from_memory ? ((size_t)1 << 30) : size;
    char *src = malloc(span), *dst = malloc(size);
    if (!src || !dst) exit(1);
    memset(src, 1, span);
    memset(dst, 2, size);
    int64_t start = now_ns();
    size_t at = 0;
    for (int64_t i = 0; i < n; i++) {
        memcpy(dst, src + at, size);
        __asm__ __volatile__("" : : "r"(dst) : "memory");
        at = from_memory ? (at + size) % span : 0;
    }
    int64_t took = now_ns() - start;
    printf("mode=memcpy size=32768 from=%s ns_per_copy=%.1f\n", from_memory ? "memory" : "cache",
           (double)took / (double)n);
    free(src);
    free(dst);
}

int main(int argc, char **argv) {
    int quick = argc > 1 && strcmp(argv[1], "--quick") == 0;
    int64_t scale = quick ? 20 : 1;
    int counts[] = { 1, 2, 4, 8, 16 };
    for (int cas = 0; cas < 2; cas++)
        for (int i = 0; i < 5; i++) contended(counts[i], cas, 20000000 / scale);
    ping_pong(0, 2000000 / scale);
    ping_pong(1, 100000 / scale);
    allocate(16, 0, 10000000 / scale);
    allocate(16, 1, 10000000 / scale);
    allocate(32768, 0, 1000000 / scale);
    allocate(32768, 1, 1000000 / scale);
    copies(0, 1000000 / scale);
    copies(1, 200000 / scale);
    return 0;
}
