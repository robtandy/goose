/* What an attach and a detach cost when every thread attaches the same
   arena: an atomic increment and decrement of one shared counter, in a
   loop on each thread (docs/design/shared_memory.md, 11.4).

       attach THREADS PAIRS_PER_THREAD */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define MAX_THREADS 64

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

static _Alignas(64) atomic_long attached;
static long pairs;

static void *worker(void *arg) {
    (void)arg;
    for (long i = 0; i < pairs; i++) {
        atomic_fetch_add_explicit(&attached, 1, memory_order_acq_rel);
        atomic_fetch_sub_explicit(&attached, 1, memory_order_acq_rel);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: attach THREADS PAIRS\n");
        return 2;
    }
    int threads = atoi(argv[1]);
    pairs = atol(argv[2]);
    if (threads < 1 || threads > MAX_THREADS || pairs < 1) return 2;
    pthread_t t[MAX_THREADS];
    int64_t t0 = now_ns();
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, worker, NULL);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    printf("attach and detach on one counter, %2d threads: %.0f ns per pair per thread\n", threads,
           (now_ns() - t0) / (double)pairs);
    return 0;
}
