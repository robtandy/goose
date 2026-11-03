/* The C side of queues.goose's event modes (bench/queues.md): a thread
   signals the owner's event n times, as an I/O layer's completion thread
   would. Before each signal it waits 50 us after the owner's last
   acknowledgement, so the owner is asleep; it times each signal from just
   before gs_event_signal until it sees the owner's acknowledgement,
   spinning. Linux and macOS. */
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include "goose.h"

static gs_res ev;
static int64_t count, *samples;
static volatile int64_t acks;
static pthread_t thread;

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void *signaller(void *p) {
    (void)p;
    for (int64_t i = 0; i < count; i++) {
        int64_t before = __atomic_load_n(&acks, __ATOMIC_ACQUIRE);
        int64_t until = now_ns() + 50000;
        while (now_ns() < until) {}
        int64_t t0 = now_ns();
        gs_event_signal(ev);
        while (__atomic_load_n(&acks, __ATOMIC_ACQUIRE) == before) {}
        samples[i] = now_ns() - t0;
    }
    return NULL;
}

void qb_events_start(gs_res e, int64_t n) {
    ev = e;
    count = n;
    samples = (int64_t *)calloc((size_t)(n > 0 ? n : 1), sizeof(int64_t));
    pthread_create(&thread, NULL, signaller, NULL);
}

void qb_events_ack(void) {
    __atomic_fetch_add(&acks, 1, __ATOMIC_ACQ_REL);
}

static int cmp(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

void qb_events_join(void) {
    pthread_join(thread, NULL);
    qsort(samples, (size_t)count, sizeof(int64_t), cmp);
}

/* 0: the median, 1: the 99th percentile, 2: the least, 3: the mean. */
int64_t qb_events_stat(int64_t k) {
    if (count <= 0) return 0;
    if (k == 0) return samples[count / 2];
    if (k == 1) return samples[count * 99 / 100];
    if (k == 2) return samples[0];
    int64_t total = 0;
    for (int64_t i = 0; i < count; i++) total += samples[i];
    return total / count;
}
