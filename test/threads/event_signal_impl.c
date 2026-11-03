/* The C side of event_signal.goose: what an I/O layer would be, whose
   completions come on threads of its own, each calling gs_event_signal
   (goose.h) with a resource<event> it was handed and kept. Nothing here
   runs Goose code or makes a handle. */
#include <stdint.h>
#include <stdlib.h>
#include "goose.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#include <sched.h>
#include <time.h>
#endif

#if defined(_MSC_VER) && !defined(__clang__)
#define LOAD(p) InterlockedCompareExchange64((volatile LONG64 *)(p), 0, 0)
#define ADD(p, v) InterlockedExchangeAdd64((volatile LONG64 *)(p), (v))
#define STORE(p, v) InterlockedExchange64((volatile LONG64 *)(p), (v))
#else
#define LOAD(p) __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define ADD(p, v) __atomic_fetch_add((p), (v), __ATOMIC_ACQ_REL)
#define STORE(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)
#endif

static void pause_us(int64_t us) {
#ifdef _WIN32
    Sleep((DWORD)((us + 999) / 1000));
#else
    struct timespec ts = { (time_t)(us / 1000000), (long)(us % 1000000) * 1000 };
    nanosleep(&ts, NULL);
#endif
}

static void yield(void) {
#ifdef _WIN32
    SwitchToThread();
#else
    sched_yield();
#endif
}

static int64_t now_us(void) {
#ifdef _WIN32
    return (int64_t)GetTickCount64() * 1000;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
#endif
}

#ifdef _WIN32
static int start(LPTHREAD_START_ROUTINE f, void *arg) {
    HANDLE h = CreateThread(NULL, 0, f, arg, 0, NULL);
    if (!h) return 0;
    CloseHandle(h);
    return 1;
}
#define THREAD_FN(name) static DWORD WINAPI name(LPVOID p)
#define THREAD_END return 0
#else
static int start(void *(*f)(void *), void *arg) {
    pthread_t t;
    if (pthread_create(&t, NULL, f, arg)) return 0;
    pthread_detach(t);
    return 1;
}
#define THREAD_FN(name) static void *name(void *p)
#define THREAD_END return NULL
#endif

/* A thread that signals e `count` times, `us` microseconds apart, then
   `done` once (unless it is the zero handle). */
typedef struct { gs_res e, done; int64_t count, us; } after_job;
THREAD_FN(after_main) {
    after_job j = *(after_job *)p;
    free(p);
    for (int64_t i = 0; i < j.count; i++) {
        if (j.us) pause_us(j.us);
        gs_event_signal(j.e);
    }
    if (j.done) gs_event_signal(j.done);
    THREAD_END;
}

int64_t io_after(gs_res e, gs_res done, int64_t count, int64_t us) {
    after_job *j = (after_job *)malloc(sizeof *j);
    if (!j) return 0;
    j->e = e;
    j->done = done;
    j->count = count;
    j->us = us;
    if (start(after_main, j)) return 1;
    free(j);
    return 0;
}

/* gs_event_signal on the calling thread: 1, 0 or -1. */
int64_t io_signal(gs_res e) {
    return gs_event_signal(e);
}

/* The storm: `threads` C threads signal e `rounds` times each, each time
   waiting for the owner to say it took a copy after the signal (io_taken).
   A wait of 20 s is a wake-up lost. The last thread to finish signals
   `over`. */
static volatile int64_t taken, lost, running;
typedef struct { gs_res e, over; int64_t rounds; } storm_job;
THREAD_FN(storm_main) {
    storm_job j = *(storm_job *)p;
    free(p);
    for (int64_t i = 0; i < j.rounds; i++) {
        int64_t before = LOAD(&taken);
        if (gs_event_signal(j.e) != 1) ADD(&lost, 1);
        int64_t t0 = now_us();
        while (LOAD(&taken) == before) {
            if (now_us() - t0 > 20000000) {
                ADD(&lost, 1);
                break;
            }
            yield();
        }
    }
    if (ADD(&running, -1) == 1) gs_event_signal(j.over);
    THREAD_END;
}

int64_t io_storm(gs_res e, gs_res over, int64_t threads, int64_t rounds) {
    STORE(&running, threads);
    for (int64_t i = 0; i < threads; i++) {
        storm_job *j = (storm_job *)malloc(sizeof *j);
        if (!j) return 0;
        j->e = e;
        j->over = over;
        j->rounds = rounds;
        if (!start(storm_main, j)) return 0;
    }
    return 1;
}

void io_taken(void) {
    ADD(&taken, 1);
}

int64_t io_lost(void) {
    return LOAD(&lost);
}
