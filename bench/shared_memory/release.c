/* What releasing memory costs when threads end together: each thread
   reserves regions the way the runtime reserves a data stack (2 GB,
   MAP_NORESERVE), touches part of each, and then every thread releases its
   regions at the same moment, by munmap, by madvise(MADV_DONTNEED), or not
   at all, keeping them for reuse (docs/design/shared_memory.md; results in
   README.md).

       release THREADS REGIONS_PER_THREAD MB_TOUCHED_PER_REGION munmap|dontneed|keep

   Linux and macOS. */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#define RESERVE (2ULL << 30)
#define MAX_THREADS 64
#define MAX_REGIONS 64

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

static int nregions;
static size_t touch;
static const char *how;
static pthread_barrier_t reserved;
/* The release phase: from the first thread's start to the last one's end,
   each measured by the thread itself, so that a main thread scheduled late
   after the barrier cannot shorten it. */
static atomic_llong first_start = INT64_MAX, last_end, slowest;

static void *worker(void *arg) {
    (void)arg;
    uint8_t *r[MAX_REGIONS];
    for (int i = 0; i < nregions; i++) {
        r[i] = mmap(NULL, RESERVE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (r[i] == MAP_FAILED) {
            perror("mmap");
            exit(1);
        }
        for (size_t o = 0; o < touch; o += 4096) r[i][o] = 1;
    }
    pthread_barrier_wait(&reserved);
    long long t0 = now_ns();
    for (int i = 0; i < nregions; i++) {
        if (!strcmp(how, "munmap")) munmap(r[i], RESERVE);
        else if (!strcmp(how, "dontneed")) madvise(r[i], touch, MADV_DONTNEED);
    }
    long long t1 = now_ns(), d = t1 - t0, v;
    v = atomic_load(&first_start);
    while (t0 < v && !atomic_compare_exchange_weak(&first_start, &v, t0)) {}
    v = atomic_load(&last_end);
    while (t1 > v && !atomic_compare_exchange_weak(&last_end, &v, t1)) {}
    v = atomic_load(&slowest);
    while (d > v && !atomic_compare_exchange_weak(&slowest, &v, d)) {}
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: release THREADS REGIONS MB munmap|dontneed|keep\n");
        return 2;
    }
    int threads = atoi(argv[1]);
    nregions = atoi(argv[2]);
    touch = (size_t)atoll(argv[3]) << 20;
    how = argv[4];
    if (threads < 1 || threads > MAX_THREADS || nregions < 1 || nregions > MAX_REGIONS) return 2;
    pthread_barrier_init(&reserved, NULL, (unsigned)threads);
    pthread_t t[MAX_THREADS];
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, worker, NULL);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    printf("%-8s threads=%2d regions=%2d touched=%4zu MB each: release %.2f ms (slowest thread %.2f ms)\n", how,
           threads, nregions, touch >> 20, (atomic_load(&last_end) - atomic_load(&first_start)) / 1e6,
           atomic_load(&slowest) / 1e6);
    return 0;
}
