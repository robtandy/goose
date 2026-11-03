/* Direct runtime test of the races of inboxes, select and events
   (docs/design/inboxes_select.md §5, §10). GS_QTEST_HOOK, empty in every
   program, parks a thread here at a chosen point of the runtime, so that
   each race plays out in one order, every run:

   * a claim and its wake-up: a put passes over a thread another put has
     claimed and claims the next one;
   * inbox first after a wake-up, and the claim passed on by a thread that
     took from another source, its inbox or another type of a select;
   * a deadline that meets a claim acts on it;
   * events closed under their copies, which stay to be taken, the record
     going back only then;
   * a signal paused before its hint, which another signal finishes, and
     one that wakes a sleeping owner when it goes on;
   * signals paused across a close, a reuse of the event's record and
     70,000 reuses of its owner's thread record, which then name nothing;
   * stale handles and the limits of handles, built a second time with
     GS_QTEST_SMALL: 5 bits of serial and 4 of index;

   and, without the hooks, signals from many C threads racing their owner's
   sleeps, every one followed by a take. A failure prints what failed; a
   hang past a check's 20 s is a failure too. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <pthread.h>
#include <sched.h>
#include <time.h>
#endif

#ifdef GS_QTEST_SMALL
#define GS_QTEST_EVENT_SERIAL_BITS 5
#define GS_QTEST_EVENT_INDEX_BITS 4
#endif
static void qt_hook(int point);
#define GS_QTEST_HOOK(point, q) ((void)(q), qt_hook(point))
#define GS_NEED_THREADS 1
#define GS_MAX_STACKS 8
#define GS_STACK_RESERVE (256u << 10)
#define GS_STACK_GAP (64u << 10)
#include "../../src/runtime/runtime.h"
#include "../../src/runtime/runtime_impl.h"
#include "../../src/runtime/runtime_threads.h"
#include "../../src/runtime/runtime_shared.h"

static void check(int ok, const char *what) {
    if (!ok) {
        fprintf(stderr, "runtime queue stall check failed: %s\n", what);
        exit(2);
    }
}

static void qt_yield(void) {
#ifdef _WIN32
    SwitchToThread();
#else
    sched_yield();
#endif
}

static void qt_sleep_ms(int ms) {
#ifdef _WIN32
    Sleep((DWORD)ms);
#else
    struct timespec ts = { 0, ms * 1000000L };
    nanosleep(&ts, NULL);
#endif
}

/* --- the hook: per test thread, a slot `who` (0 for main and C threads
   that park nowhere) and the one point it parks at next. */

#define QT_SLOTS 8
static gs_mutex qt_mutex = GS_MUTEX_INIT;
static GS_TLS int qt_who;
static GS_TLS int qt_park = -1;
static volatile int qt_parked[QT_SLOTS], qt_released[QT_SLOTS], qt_asleep[QT_SLOTS];
static volatile int qt_done[QT_SLOTS];
static volatile int64_t qt_val[QT_SLOTS];

static void qt_hook(int point) {
    if (point == GS_QT_SLEEP) {
        if (!qt_who) return;
        gs_mutex_lock(&qt_mutex);
        qt_asleep[qt_who]++;
        gs_mutex_unlock(&qt_mutex);
        return;
    }
    if (point != qt_park) return;
    qt_park = -1;
    gs_mutex_lock(&qt_mutex);
    qt_parked[qt_who] = 1;
    gs_mutex_unlock(&qt_mutex);
    for (;;) {
        gs_mutex_lock(&qt_mutex);
        int go = qt_released[qt_who];
        if (go) qt_released[qt_who] = qt_parked[qt_who] = 0;
        gs_mutex_unlock(&qt_mutex);
        if (go) return;
        qt_sleep_ms(1);
    }
}

static int qt_read(volatile int *p) {
    gs_mutex_lock(&qt_mutex);
    int v = *p;
    gs_mutex_unlock(&qt_mutex);
    return v;
}

/* Waits up to 20 s for *p to reach n. */
static void qt_until(volatile int *p, int n, const char *what) {
    for (int ms = 0; qt_read(p) < n; ms++) {
        check(ms < 20000, what);
        qt_sleep_ms(1);
    }
}

static void qt_release(int who) {
    gs_mutex_lock(&qt_mutex);
    qt_released[who] = 1;
    gs_mutex_unlock(&qt_mutex);
}

static void qt_reset(void) {
    gs_mutex_lock(&qt_mutex);
    for (int i = 0; i < QT_SLOTS; i++) {
        qt_parked[i] = qt_released[i] = qt_asleep[i] = qt_done[i] = 0;
        qt_val[i] = -2;
    }
    gs_mutex_unlock(&qt_mutex);
}

static void qt_finish(int who, int64_t v) {
    gs_mutex_lock(&qt_mutex);
    qt_val[who] = v;
    qt_done[who] = 1;
    gs_mutex_unlock(&qt_mutex);
}

static int64_t qt_value(int who) {
    gs_mutex_lock(&qt_mutex);
    int64_t v = qt_val[who];
    gs_mutex_unlock(&qt_mutex);
    return v;
}

/* --- C threads, which are no Goose thread: they signal events. */

typedef struct {
    gs_res e;
    int park;
    int who;
    volatile int result;
} qt_signaller;

#ifdef _WIN32
static DWORD WINAPI qt_signal_main(LPVOID p)
#else
static void *qt_signal_main(void *p)
#endif
{
    qt_signaller *s = (qt_signaller *)p;
    qt_who = s->who;
    qt_park = s->park;
    int r = gs_event_signal(s->e);
    gs_mutex_lock(&qt_mutex);
    s->result = r;
    qt_done[s->who] = 1;
    gs_mutex_unlock(&qt_mutex);
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

#ifdef _WIN32
typedef HANDLE qt_thread;
static qt_thread qt_start(DWORD (WINAPI *f)(LPVOID), void *arg) {
    HANDLE h = CreateThread(NULL, 0, f, arg, 0, NULL);
    check(h != NULL, "start a C thread");
    return h;
}
static void qt_join(qt_thread t) {
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
}
#else
typedef pthread_t qt_thread;
static qt_thread qt_start(void *(*f)(void *), void *arg) {
    pthread_t t;
    check(!pthread_create(&t, NULL, f, arg), "start a C thread");
    return t;
}
static void qt_join(qt_thread t) {
    pthread_join(t, NULL);
}
#endif

/* --- Goose workers. */

static gs_queue q_t = GS_QUEUE_INIT, q_u = GS_QUEUE_INIT;

typedef struct {
    int who, park;
    int64_t ms;        /* below zero: qget; else qget(ms) */
    uint32_t at;       /* select<T, U>'s rotation; 9: a plain take of q_t */
} qt_take_args;

static void qt_taker(uint8_t *args) {
    qt_take_args a;
    memcpy(&a, args, sizeof a);
    qt_who = a.who;
    qt_park = a.park;
    gs_qmsg m;
    int64_t v = -1;
    if (a.at == 9) {
        int got = 1;
        if (a.ms < 0) gs_qget(&q_t, &m);
        else got = gs_qwait(&q_t, a.ms, &m);
        if (got) memcpy(&v, m.data, sizeof v);
    } else {
        gs_queue *const qs[2] = { &q_t, &q_u };
        uint32_t at = a.at;
        int64_t tag = gs_qselect(qs, 2, a.ms, &at, &m);
        if (tag >= 0) memcpy(&v, m.data, sizeof v);
        if (tag >= 0) v += tag * 1000;
    }
    gs_qdone(&m);
    qt_finish(a.who, v);
}

static int64_t qt_spawn_taker(int who, int park, int64_t ms, uint32_t at) {
    qt_take_args a = { who, park, ms, at };
    return gs_thread_spawn(qt_taker, &a, sizeof a, 0);
}

static void qt_put(gs_queue *q, int64_t v) {
    check(gs_qput(q, &v, sizeof v), "a put");
}

static int qt_poll(gs_queue *q, int64_t *v) {
    gs_qmsg m;
    int got = gs_qwait(q, 0, &m);
    if (got) memcpy(v, m.data, sizeof *v);
    gs_qdone(&m);
    return got;
}

static void qt_wait_all(int64_t *ids, int n) {
    for (int i = 0; i < n; i++) gs_thread_wait(ids[i], NULL, NULL, __FILE__, __LINE__);
}

#ifndef GS_QTEST_SMALL

/* Two takers asleep on q_t, the first claimed and held awake: a second put
   passes it over and claims the other. */
static void claim_and_wake(void) {
    qt_reset();
    int64_t ids[2];
    ids[0] = qt_spawn_taker(1, GS_QT_WAKE, -1, 9);
    qt_until(&qt_asleep[1], 1, "the first taker sleeps");
    ids[1] = qt_spawn_taker(2, -1, -1, 9);
    qt_until(&qt_asleep[2], 1, "the second taker sleeps");
    qt_put(&q_t, 10);
    qt_until(&qt_parked[1], 1, "the first put claims the first taker");
    qt_put(&q_t, 20);
    qt_until(&qt_done[2], 1, "the second put claims the second taker, not the claimed one");
    check(qt_value(2) == 10, "the second taker takes the oldest message");
    qt_release(1);
    qt_until(&qt_done[1], 1, "the claimed taker goes on");
    check(qt_value(1) == 20, "the claimed taker takes the other message");
    int64_t v;
    check(!qt_poll(&q_t, &v), "nothing is left");
    qt_wait_all(ids, 2);
}

/* A taker claimed by q_t's put and held awake gets a message in its inbox:
   it takes that first, and passes the claim to the other taker, asleep on
   q_t, which then takes the put's message. */
static void inbox_first(void) {
    qt_reset();
    int64_t ids[2];
    ids[0] = qt_spawn_taker(1, GS_QT_WAKE, 30000, 9);
    qt_until(&qt_asleep[1], 1, "the first taker sleeps");
    ids[1] = qt_spawn_taker(2, -1, 30000, 9);
    qt_until(&qt_asleep[2], 1, "the second taker sleeps");
    qt_put(&q_t, 100);
    qt_until(&qt_parked[1], 1, "the put claims the first taker");
    int64_t v = 200;
    check(gs_qput_to(&q_t, ids[0], &v, sizeof v, __FILE__, __LINE__), "a put to its inbox");
    qt_release(1);
    qt_until(&qt_done[1], 1, "the claimed taker goes on");
    check(qt_value(1) == 200, "inbox first after a wake-up");
    qt_until(&qt_done[2], 1, "the claim passes to the other taker");
    check(qt_value(2) == 100, "the other taker takes the put's message");
    qt_wait_all(ids, 2);
}

/* The same across a select's types: claimed by q_t's put, a select that
   looks at q_u first takes q_u's message and passes q_t's claim on. */
static void select_passes_claim(void) {
    qt_reset();
    int64_t ids[2];
    ids[0] = qt_spawn_taker(1, GS_QT_WAKE, -1, 1);
    qt_until(&qt_asleep[1], 1, "the select sleeps");
    ids[1] = qt_spawn_taker(2, -1, -1, 9);
    qt_until(&qt_asleep[2], 1, "the taker sleeps");
    qt_put(&q_t, 7);
    qt_until(&qt_parked[1], 1, "q_t's put claims the select");
    qt_put(&q_u, 8);
    qt_release(1);
    qt_until(&qt_done[1], 1, "the select goes on");
    check(qt_value(1) == 1008, "the select's rotation takes q_u's message");
    qt_until(&qt_done[2], 1, "the select passes q_t's claim to the taker");
    check(qt_value(2) == 7, "the taker takes q_t's message");
    qt_wait_all(ids, 2);
}

/* A timed take past its deadline, held there, is claimed by a put: it
   acts on the claim and takes the message, which a later sleeper on q_t,
   not claimed, never sees. */
static void deadline_meets_claim(void) {
    qt_reset();
    int64_t ids[2];
    ids[0] = qt_spawn_taker(1, GS_QT_DEADLINE, 30, 9);
    qt_until(&qt_asleep[1], 1, "the timed taker sleeps");
    ids[1] = qt_spawn_taker(2, -1, 300, 9);
    qt_until(&qt_asleep[2], 1, "the second taker sleeps");
    qt_until(&qt_parked[1], 1, "the timed taker passes its deadline");
    qt_put(&q_t, 33);
    qt_release(1);
    qt_until(&qt_done[1], 1, "the timed taker goes on");
    check(qt_value(1) == 33, "a deadline that meets a claim takes the message");
    qt_until(&qt_done[2], 1, "the second taker's deadline");
    check(qt_value(2) == -1, "the second taker gets nothing");
    qt_wait_all(ids, 2);
}

static int64_t qt_index(gs_res e) {
    return (int64_t)(e & GS_EVENT_INDEX_MASK);
}

/* An event closed with its copy pending: the copy stays and is taken, and
   the record goes back only then. */
static void closed_under_copy(void) {
    int64_t v = 1, w = 0;
    gs_res e = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(gs_event_signal(e) == 1, "a signal of an open event");
    gs_event_close(e, __FILE__, __LINE__);
    check(gs_event_signal(e) == 0, "a signal after the close");
    v = 2;
    gs_res e2 = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(qt_index(e2) != qt_index(e), "a record with a copy pending is not reused");
    check(qt_poll(&q_t, &w) && w == 1, "the closed event's copy is taken");
    check(!qt_poll(&q_t, &w), "once");
    gs_event_close(e2, __FILE__, __LINE__);
    v = 3;
    gs_res e3 = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(qt_index(e3) == qt_index(e2), "a record without one goes back at the close");
    gs_res e4 = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(qt_index(e4) == qt_index(e), "and one whose copy was taken, after the take");
    check(gs_event_signal(e) == 0 && gs_event_signal(e2) == 0, "old handles are stale");
    check(gs_event_signal(e4) == 1, "the new event's");
    check(qt_poll(&q_t, &w) && w == 3, "takes the new event's copy");
    gs_event_close(e3, __FILE__, __LINE__);
    gs_event_close(e4, __FILE__, __LINE__);
    check(!qt_poll(&q_t, &w), "nothing is left");
}

/* A signal paused after setting `pending`, before its hint: the copy can't
   be seen yet; another signal merges, sets the hint, and it is taken; the
   paused one's hint, later, has nothing pending. */
static void hint_finished_by_another(void) {
    qt_reset();
    int64_t v = 5, w = 0;
    gs_res e = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    qt_signaller a = { e, GS_QT_SIGNAL_HINT, 1, -9 }, b = { e, -1, 2, -9 };
    qt_thread ta = qt_start(qt_signal_main, &a);
    qt_until(&qt_parked[1], 1, "the signal pauses before its hint");
    check(!qt_poll(&q_t, &w), "no hint, no copy yet");
    qt_thread tb = qt_start(qt_signal_main, &b);
    qt_join(tb);
    check(b.result == 1, "a second signal merges");
    check(qt_poll(&q_t, &w) && w == 5, "and its hint shows the copy");
    check(!qt_poll(&q_t, &w), "one copy for both");
    qt_release(1);
    qt_join(ta);
    check(a.result == 1, "the paused signal returns 1");
    check(!qt_poll(&q_t, &w), "its hint finds nothing pending");
    gs_event_close(e, __FILE__, __LINE__);
}

/* The owner asleep while a signal is paused before its hint: going on, the
   signal sets the hint and wakes it. */
static gs_res owner_event;
static void sleeping_owner(uint8_t *args) {
    (void)args;
    qt_who = 3;
    int64_t v = 6;
    gs_res e = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    gs_mutex_lock(&qt_mutex);
    owner_event = e;
    gs_mutex_unlock(&qt_mutex);
    gs_qmsg m;
    gs_qget(&q_t, &m);
    memcpy(&v, m.data, sizeof v);
    gs_qdone(&m);
    gs_event_close(e, __FILE__, __LINE__);
    qt_finish(3, v);
}

static void hint_wakes_owner(void) {
    qt_reset();
    int64_t id = gs_thread_spawn(sleeping_owner, NULL, 0, 0);
    qt_until(&qt_asleep[3], 1, "the owner sleeps");
    gs_mutex_lock(&qt_mutex);
    gs_res e = owner_event;
    gs_mutex_unlock(&qt_mutex);
    qt_signaller a = { e, GS_QT_SIGNAL_HINT, 1, -9 };
    qt_thread ta = qt_start(qt_signal_main, &a);
    qt_until(&qt_parked[1], 1, "the signal pauses before its hint");
    qt_sleep_ms(20);
    check(!qt_read(&qt_done[3]), "the owner sleeps on, no hint set");
    qt_release(1);
    qt_join(ta);
    check(a.result == 1, "the signal returns 1");
    qt_until(&qt_done[3], 1, "the owner wakes for the copy");
    check(qt_value(3) == 6, "and takes it");
    gs_thread_wait(id, NULL, NULL, __FILE__, __LINE__);
}

/* A signal paused after reading its event, across a close and a new event
   in the same record: it returns 0, and the new event has nothing pending. */
static void signal_across_close(void) {
    qt_reset();
    int64_t v = 8, w = 0;
    gs_res e = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    qt_signaller a = { e, GS_QT_SIGNAL_READ, 1, -9 };
    qt_thread ta = qt_start(qt_signal_main, &a);
    qt_until(&qt_parked[1], 1, "the signal pauses after reading the event");
    gs_event_close(e, __FILE__, __LINE__);
    gs_res e2 = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(qt_index(e2) == qt_index(e), "the record is reused");
    qt_release(1);
    qt_join(ta);
    check(a.result == 0, "a signal across a close and a reuse returns 0");
    check(!qt_poll(&q_t, &w), "and makes nothing pending");
    gs_event_close(e2, __FILE__, __LINE__);
}

/* The same across 70,000 reuses of the owner's thread record, each new
   owner making an event in the event's record: the last owner sees
   nothing. An owner closes its event (mode 0), leaves it to its end (2), or
   publishes it and looks for a copy when told to (1). */
static volatile int reuse_go;
static gs_res reuse_event;
static void reuse_owner(uint8_t *args) {
    int64_t mode;
    memcpy(&mode, args, sizeof mode);
    int64_t v = 9;
    gs_res e = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    if (!mode) {
        gs_event_close(e, __FILE__, __LINE__);
        return;
    }
    gs_mutex_lock(&qt_mutex);
    reuse_event = e;
    gs_mutex_unlock(&qt_mutex);
    qt_until(&reuse_go, 1, "an owner is told to go on");
    if (mode == 2) return;
    gs_qmsg m;
    int got = gs_qwait(&q_t, 0, &m);
    gs_qdone(&m);
    gs_event_close(e, __FILE__, __LINE__);
    qt_finish(4, got);
}

static gs_res reuse_published(void) {
    for (int ms = 0;; ms++) {
        gs_mutex_lock(&qt_mutex);
        gs_res e = reuse_event;
        reuse_event = 0;
        gs_mutex_unlock(&qt_mutex);
        if (e) return e;
        check(ms < 20000, "an owner makes its event");
        qt_sleep_ms(1);
    }
}

static void reuse_tell(int go) {
    gs_mutex_lock(&qt_mutex);
    reuse_go = go;
    gs_mutex_unlock(&qt_mutex);
}

static void signal_across_reuses(void) {
    qt_reset();
    reuse_tell(0);
    int64_t keep = 2, close = 0, look = 1;
    int64_t first = gs_thread_spawn(reuse_owner, &keep, sizeof keep, 0);
    gs_res e = reuse_published();
    gs_mutex_lock(&gs_threads_mutex);
    gs_thread *rec = gs_live_find(first);
    gs_mutex_unlock(&gs_threads_mutex);
    qt_signaller a = { e, GS_QT_SIGNAL_READ, 1, -9 };
    qt_thread ta = qt_start(qt_signal_main, &a);
    qt_until(&qt_parked[1], 1, "the signal pauses after reading the event");
    /* The owner ends, which closes its event. */
    reuse_tell(1);
    gs_thread_wait(first, NULL, NULL, __FILE__, __LINE__);
    reuse_tell(0);
    int reused = 0;
    for (int i = 0; i < 70000; i++) {
        int64_t id = gs_thread_spawn(reuse_owner, &close, sizeof close, 0);
        gs_mutex_lock(&gs_threads_mutex);
        reused += gs_live_find(id) == rec;
        gs_mutex_unlock(&gs_threads_mutex);
        gs_thread_wait(id, NULL, NULL, __FILE__, __LINE__);
    }
    check(reused > 60000, "the owner's record is reused");
    int64_t last = gs_thread_spawn(reuse_owner, &look, sizeof look, 0);
    gs_res e2 = reuse_published();
    check(qt_index(e2) == qt_index(e) && e2 != e, "in the same event record");
    qt_release(1);
    qt_join(ta);
    check(a.result == 0, "a signal across 70,000 reuses returns 0");
    reuse_tell(1);
    qt_until(&qt_done[4], 1, "the last owner looks");
    check(qt_value(4) == 0, "and nothing reached it");
    gs_thread_wait(last, NULL, NULL, __FILE__, __LINE__);
}

/* Signals from many C threads at once, racing the owner's sleeps, each
   waiting until a take follows its signal: a lost wake-up leaves one
   waiting for good. */
#define QT_SIGNALLERS 8
#define QT_ROUNDS 5000
static volatile int64_t stress_takes;
static volatile int stress_stop;
static gs_res stress_event;
static void stress_owner(uint8_t *args) {
    (void)args;
    int64_t v = 1;
    gs_res e = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    gs_mutex_lock(&qt_mutex);
    stress_event = e;
    gs_mutex_unlock(&qt_mutex);
    for (;;) {
        gs_qmsg m;
        gs_qget(&q_t, &m);
        gs_qdone(&m);
        gs_aadd(&stress_takes, 1);
        if (qt_read(&stress_stop)) break;
    }
    gs_event_close(e, __FILE__, __LINE__);
}

#ifdef _WIN32
static DWORD WINAPI stress_signaller(LPVOID p)
#else
static void *stress_signaller(void *p)
#endif
{
    gs_res e = *(gs_res *)p;
    for (int i = 0; i < QT_ROUNDS; i++) {
        int64_t before = gs_aload(&stress_takes);
        check(gs_event_signal(e) == 1, "a signal of an open event");
        /* A wake-up takes microseconds; a lost one, forever. */
        int64_t t0 = gs_qclock_ns();
        while (gs_aload(&stress_takes) == before) {
            qt_yield();
            check(gs_qclock_ns() - t0 < (int64_t)20000000000, "a take follows every signal: "
                                                               "a wake-up was lost");
        }
    }
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static void signal_stress(void) {
    int64_t id = gs_thread_spawn(stress_owner, NULL, 0, 0);
    gs_res e;
    for (int ms = 0;; ms++) {
        gs_mutex_lock(&qt_mutex);
        e = stress_event;
        gs_mutex_unlock(&qt_mutex);
        if (e) break;
        check(ms < 20000, "the owner makes its event");
        qt_sleep_ms(1);
    }
    qt_thread t[QT_SIGNALLERS];
    for (int i = 0; i < QT_SIGNALLERS; i++) t[i] = qt_start(stress_signaller, &e);
    for (int i = 0; i < QT_SIGNALLERS; i++) qt_join(t[i]);
    gs_mutex_lock(&qt_mutex);
    stress_stop = 1;
    gs_mutex_unlock(&qt_mutex);
    /* The owner may have closed it, seeing the stop after a take. */
    check(gs_event_signal(e) >= 0, "the last signal");
    gs_thread_wait(id, NULL, NULL, __FILE__, __LINE__);
    check(gs_event_signal(e) == 0, "the owner's close");
    check(gs_aload(&stress_takes) >= QT_ROUNDS, "copies were taken");
}

#else  /* GS_QTEST_SMALL */

/* The handles' limits at 5 bits of serial and 4 of index: 31 serials, 16
   records. */
static void open_sixteen(uint8_t *args) {
    (void)args;
    int64_t v = 0;
    for (int i = 0; i < 17; i++) gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
}

static void use_serials(uint8_t *args) {
    (void)args;
    int64_t v = 0;
    for (int i = 0; i < 64; i++)
        gs_event_close(gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__), __FILE__, __LINE__);
}

/* Whether an abort's message, `len` bytes, holds `want`. */
static int qt_msg_has(const uint8_t *msg, int64_t len, const char *want) {
    size_t n = strlen(want);
    for (int64_t i = 0; msg && i + (int64_t)n <= len; i++)
        if (!memcmp(msg + i, want, n)) return 1;
    return 0;
}

static void small_handles(void) {
    int64_t v = 1, w = 0;
    gs_res e1 = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(e1 == ((gs_res)1 << 4 | 0), "serial 1, index 0");
    check(gs_event_signal(0) == -1, "the zero handle names no event");
    check(gs_event_signal((gs_res)2 << 4 | 0) == -1, "a serial newer than its record's was never handed out");
    check(gs_event_signal((gs_res)1 << 4 | 9) == -1, "nor a record never made");
    check(gs_event_signal((gs_res)1 << 63 | 0) == -1, "nor bits past the widths");
    check(gs_event_signal(e1) == 1, "an open event");
    check(qt_poll(&q_t, &w) && w == 1, "its copy");
    gs_event_close(e1, __FILE__, __LINE__);
    check(gs_event_signal(e1) == 0, "a closed one");
    v = 2;
    gs_res e2 = gs_event_new(&q_t, &v, sizeof v, __FILE__, __LINE__);
    check(e2 == ((gs_res)2 << 4 | 0), "serial 2 in the same record");
    check(gs_event_signal(e1) == 0, "an older serial is stale");
    check(gs_event_signal((gs_res)31 << 4 | 0) == -1, "a newer one never named an event");
    check(gs_event_signal(e2) == 1 && qt_poll(&q_t, &w) && w == 2, "the new event's");
    gs_event_close(e2, __FILE__, __LINE__);
    /* Sixteen open at once, then the seventeenth: an abort, contained. */
    uint8_t *msg;
    int64_t len;
    int64_t id = gs_thread_spawn(open_sixteen, NULL, 0, 1);
    check(!gs_thread_wait(id, &msg, &len, __FILE__, __LINE__), "the seventeenth open event aborts");
    check(qt_msg_has(msg, len, "too many open events"), "too many open events");
    gs_free_msg(msg);
    /* Serials 19 to 31, then none: an abort too. */
    id = gs_thread_spawn(use_serials, NULL, 0, 1);
    check(!gs_thread_wait(id, &msg, &len, __FILE__, __LINE__), "the 32nd event aborts");
    check(qt_msg_has(msg, len, "event serials are used up"), "event serials are used up");
    gs_free_msg(msg);
    check(gs_event_signal(e2) == 0, "every handle made is stale or closed");
}

#endif

int main(void) {
    gs_rt_init(0, NULL, 1, 1, GS_MAX_STACKS);
    gs_qinit(&q_t);
    gs_qinit(&q_u);
#ifndef GS_QTEST_SMALL
    claim_and_wake();
    inbox_first();
    select_passes_claim();
    deadline_meets_claim();
    closed_under_copy();
    hint_finished_by_another();
    hint_wakes_owner();
    signal_across_close();
    check(gs_event_signal((gs_res)1 << 24 | (1 << 20)) == -1, "an index past the table");
    signal_across_reuses();
    signal_stress();
    puts("runtime queue stalls ok");
#else
    small_handles();
    puts("runtime queue stalls (small handles) ok");
#endif
    return 0;
}
