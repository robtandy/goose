/* What making a written region read-only costs, which is what freezing
   would pay if it protected every frozen region (docs/design/shared_memory.md,
   11.3): mprotect(PROT_READ) of a region whose pages are all written, alone
   and while other threads run, whose cached translations the system must
   then drop.

       mprot OTHER_THREADS MB

   Linux and macOS. */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>

#define MAX_THREADS 64
#define REPS 200

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

static atomic_int stop;

/* Keeps a core busy reading memory of its own. */
static void *spin(void *arg) {
    (void)arg;
    volatile uint8_t *p = calloc(1, 1 << 20);
    uint64_t s = 0;
    while (!atomic_load(&stop))
        for (int i = 0; i < (1 << 20); i += 64) s += p[i];
    free((void *)p);
    return (void *)(uintptr_t)s;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: mprot OTHER_THREADS MB\n");
        return 2;
    }
    int others = atoi(argv[1]);
    size_t size = (size_t)atoll(argv[2]) << 20;
    if (others < 0 || others > MAX_THREADS || size == 0) return 2;
    pthread_t t[MAX_THREADS];
    for (int i = 0; i < others; i++) pthread_create(&t[i], NULL, spin, NULL);
    int64_t total = 0;
    for (int r = 0; r < REPS; r++) {
        uint8_t *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) return 1;
        for (size_t o = 0; o < size; o += 4096) p[o] = 1;
        int64_t t0 = now_ns();
        mprotect(p, size, PROT_READ);
        total += now_ns() - t0;
        munmap(p, size);
    }
    atomic_store(&stop, 1);
    for (int i = 0; i < others; i++) pthread_join(t[i], NULL);
    printf("mprotect(PROT_READ) of %zu MB written, %2d other threads running: %.1f us\n", size >> 20, others,
           total / 1e3 / REPS);
    return 0;
}
