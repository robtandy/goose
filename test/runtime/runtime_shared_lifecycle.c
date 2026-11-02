/* Direct runtime regression for shared memory (spec §11.4,
   docs/design/shared_memory.md): arenas made, attached to, mapped into and
   released over and over leak no memory, mapping or handle; a stale handle,
   the zero handle and a view that does not fit abort, ending only the
   contained worker they are in; a contained worker that aborts holding
   attachments ends them; small limits on serials and regions abort with
   their messages; and a read past the end of a file truncated while
   mapped, or a write to a mapping, ends the process with a message naming
   the file. */
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
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#endif

static volatile long live_allocations, live_mappings;

static long counter_add(volatile long *p, long n) {
#ifdef _WIN32
    return InterlockedExchangeAdd(p, n);
#else
    return __sync_fetch_and_add(p, n);
#endif
}

static void check(int ok, const char *what) {
    if (!ok) {
        fprintf(stderr, "runtime shared lifecycle check failed: %s\n", what);
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

static void *counted_realloc(void *old, size_t size) {
    void *p = realloc(old, size);
    if (p && !old) counter_add(&live_allocations, 1);
    return p;
}

static void counted_free(void *p) {
    if (p) counter_add(&live_allocations, -1);
    free(p);
}

#ifdef _WIN32
static LPVOID counted_map_view(HANDLE m, DWORD access, DWORD hi, DWORD lo, SIZE_T n) {
    LPVOID p = MapViewOfFile(m, access, hi, lo, n);
    if (p) counter_add(&live_mappings, 1);
    return p;
}

static BOOL counted_unmap_view(LPCVOID p) {
    BOOL ok = UnmapViewOfFile(p);
    if (ok) counter_add(&live_mappings, -1);
    return ok;
}
#define MapViewOfFile counted_map_view
#define UnmapViewOfFile counted_unmap_view
#else
static void *counted_mmap(void *base, size_t size, int prot, int flags, int fd, off_t off) {
    void *p = mmap(base, size, prot, flags, fd, off);
    if (p != MAP_FAILED) counter_add(&live_mappings, 1);
    return p;
}

static int counted_munmap(void *base, size_t size) {
    int result = munmap(base, size);
    if (!result) counter_add(&live_mappings, -1);
    return result;
}
#define mmap counted_mmap
#define munmap counted_munmap
#endif

#define malloc counted_malloc
#define calloc counted_calloc
#define realloc counted_realloc
#define free counted_free
#define GS_NEED_THREADS 1
#define GS_MAX_STACKS 2
#define GS_STACK_RESERVE (256u << 10)
#define GS_STACK_GAP (64u << 10)
/* Small enough to reach: the serials churn, the stale handles and the
   limit's own test take, and a few regions per arena. */
#define GS_SHM_MAX_SERIAL 600
#define GS_SHM_MAX_REGIONS 4
#include "../../src/runtime/runtime.h"
#include "../../src/runtime/runtime_impl.h"
#include "../../src/runtime/runtime_threads.h"
#include "../../src/runtime/runtime_shared.h"

static char dir[512], col[600], empty[600], missing[600];

static void write_file(const char *path, const void *data, size_t n) {
    FILE *f = fopen(path, "wb");
    check(f != NULL, "create a scratch file");
    check(fwrite(data, 1, n, f) == n, "write a scratch file");
    check(fclose(f) == 0, "close a scratch file");
}

static void make_files(void) {
#ifdef _WIN32
    char tmp[MAX_PATH];
    check(GetTempPathA(sizeof tmp, tmp) > 0, "find the temporary directory");
    snprintf(dir, sizeof dir, "%sgoose_shared_%lu", tmp, (unsigned long)GetCurrentProcessId());
    check(CreateDirectoryA(dir, NULL) != 0, "make a scratch directory");
#else
    const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof dir, "%s/goose_shared_XXXXXX", tmp && *tmp ? tmp : "/tmp");
    check(mkdtemp(dir) != NULL, "make a scratch directory");
#endif
    int64_t v[64];
    for (int i = 0; i < 64; i++) v[i] = i * 3;
    snprintf(col, sizeof col, "%s/col.i64", dir);
    snprintf(empty, sizeof empty, "%s/empty", dir);
    snprintf(missing, sizeof missing, "%s/missing", dir);
    write_file(col, v, sizeof v);
    write_file(empty, "", 0);
}

/* What a message says, the scratch directory written <dir>, and, where
   `num` is not NULL, that number written <n>; up to its location. */
static void print_normalized(const char *lead, const uint8_t *msg, int64_t len, const char *num) {
    char text[2048], out[2048];
    int64_t k = 0;
    while (k < len && msg[k] != '\n' && !(msg[k] == ' ' && k + 1 < len && msg[k + 1] == '('))
        k++;
    snprintf(text, sizeof text, "%.*s", (int)k, (const char *)msg);
    size_t dl = strlen(dir), nl = num ? strlen(num) : 0, j = 0;
    for (const char *p = text; *p && j < sizeof out - 8;) {
        if (!strncmp(p, dir, dl)) {
            memcpy(out + j, "<dir>", 5);
            j += 5;
            p += dl;
        } else if (num && !strncmp(p, num, nl)) {
            memcpy(out + j, "<n>", 3);
            j += 3;
            p += nl;
        } else {
            out[j++] = *p++;
        }
    }
    out[j] = 0;
    printf("%s%s\n", lead, out);
}

static gs_res map(gs_att *a, const char *path) {
    gs_res m;
    uint8_t *why;
    int64_t n;
    check(gs_shm_map_file(a, (const uint8_t *)path, (int64_t)strlen(path), &m, &why, &n,
                          __FILE__, __LINE__),
          "map a file");
    check(why == NULL && m != 0, "a mapped file has a handle and no reason");
    return m;
}

static int64_t sum(const uint8_t *p, int64_t n) {
    int64_t s = 0, x;
    for (int64_t i = 0; i < n; i++) {
        memcpy(&x, p + 8 * i, 8);
        s += x;
    }
    return s;
}

/* A worker's argument: the arena's handle and the column's. */
typedef struct {
    gs_res arena, column;
} handles;

static handles args_of(const uint8_t *args) {
    handles h;
    memcpy(&h, args, sizeof h);
    return h;
}

/* An attachment of its own, and views of the column. */
static void viewer(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
    for (int i = 0; i < 100; i++) {
        check(gs_shm_size(&a, h.column, __FILE__, __LINE__) == 512, "a worker sees the size");
        const uint8_t *p = gs_shm_view(&a, h.column, 64 * (i % 8), 8, 8, 8, "i64", __FILE__,
                                       __LINE__);
        check(sum(p, 8) == 3 * (64 * (i % 8) + 28), "a worker reads the mapping in place");
    }
    gs_shm_detach(&a);
}

/* Attaches, and holds its attachment past main's: its end is the last. */
static gs_mutex test_mutex = GS_MUTEX_INIT;
static gs_cond test_cond = GS_COND_INIT;
static int attached, main_detached;

static void last_holder(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
    gs_mutex_lock(&test_mutex);
    attached = 1;
    gs_cond_broadcast(&test_cond);
    while (!main_detached) gs_cond_wait(&test_cond, &test_mutex);
    gs_mutex_unlock(&test_mutex);
    check(sum(gs_shm_view(&a, h.column, 0, 64, 8, 8, "i64", __FILE__, __LINE__), 64) == 3 * 2016,
          "the mapping outlives main's attachment");
    gs_shm_detach(&a);
}

/* Aborts holding two attachments, which its end then has to end. */
static void holder(uint8_t *args) {
    handles h = args_of(args);
    gs_att a, b;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
    gs_shm_attach(&b, h.arena, __FILE__, __LINE__);
    check(gs_shm_view(&b, h.column, 0, 64, 8, 8, "i64", __FILE__, __LINE__) != NULL,
          "a view before the abort");
    gs_abort(GS_E_ASSERT, __FILE__, __LINE__);
}

static void stale(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
}

static void out_of_bounds(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
    gs_shm_view(&a, h.column, 8, 64, 8, 8, "i64", __FILE__, __LINE__);
}

static void misaligned(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
    gs_shm_view(&a, h.column, 4, 2, 8, 8, "i64", __FILE__, __LINE__);
}

static void zero_view(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_attach(&a, h.arena, __FILE__, __LINE__);
    gs_shm_view(&a, 0, 0, 0, 8, 8, "i64", __FILE__, __LINE__);
}

static void foreign(uint8_t *args) {
    handles h = args_of(args);
    gs_att a;
    gs_shm_new(&a, __FILE__, __LINE__);
    gs_shm_view(&a, h.column, 0, 1, 8, 8, "i64", __FILE__, __LINE__);
}

/* A refusal's reason, and then an abort before the program is done with it,
   as an append of it to a `why` with no room aborts: the reason is freed
   with the rest of what the worker holds. */
static void refused_then_full(uint8_t *args) {
    (void)args;
    gs_att a;
    gs_shm_new(&a, __FILE__, __LINE__);
    gs_res m;
    uint8_t *why;
    int64_t n;
    check(!gs_shm_map_file(&a, (const uint8_t *)missing, (int64_t)strlen(missing), &m, &why, &n,
                           __FILE__, __LINE__) && why,
          "a refusal with a reason");
    gs_abort(GS_E_CAPACITY, __FILE__, __LINE__);
}

static void too_many_regions(uint8_t *args) {
    (void)args;
    gs_att a;
    gs_shm_new(&a, __FILE__, __LINE__);
    for (int i = 0; i < 5; i++) map(&a, col);
}

static void serials(uint8_t *args) {
    (void)args;
    for (;;) {
        gs_att a;
        gs_shm_new(&a, __FILE__, __LINE__);
        gs_shm_detach(&a);
    }
}

/* The fault handlers' lookup while another thread reuses an entry for
   ranges of other places and sizes, as arenas made and released do: the
   lookup sees an entry whole or not at all, so it finds Y, and never a
   reused entry's old base with its new, longer length, which would cover
   Y. The ranges are numbers only, as the lookup only compares them. */
#define FAKE_Y ((uintptr_t)1 << 40)
static int reuse_done;

static void reuser(uint8_t *args) {
    (void)args;
    for (int i = 0; i < 200000; i++) {
        gs_shm_lock();
        gs_shm_clear_fault(gs_shm_add_fault((const uint8_t *)(FAKE_Y - 4096), 4096, "X"));
        gs_shm_unlock();
        gs_shm_lock();
        gs_shm_clear_fault(gs_shm_add_fault((const uint8_t *)(FAKE_Y << 1), 1 << 20, "Z"));
        gs_shm_unlock();
    }
    __atomic_store_n(&reuse_done, 1, __ATOMIC_RELEASE);
}

static void lookups_during_reuse(void) {
    /* The reused entry is before Y's, which the lookup then reads first:
       Y is added after another entry, which is then cleared for the
       reuser's. */
    gs_shm_lock();
    int64_t before = gs_shm_add_fault((const uint8_t *)(FAKE_Y << 2), 4096, "W");
    int64_t y = gs_shm_add_fault((const uint8_t *)FAKE_Y, 4096, "Y");
    gs_shm_clear_fault(before);
    gs_shm_unlock();
    check(before < y, "the reused entry is looked at first");
    int64_t id = gs_thread_spawn(reuser, NULL, 0, 0);
    long looked = 0, wrong = 0;
    while (!__atomic_load_n(&reuse_done, __ATOMIC_ACQUIRE)) {
        gs_mapsnap e;
        if (!gs_mapfault((const void *)(FAKE_Y + 100), &e) || e.base != FAKE_Y ||
            e.len != 4096 || strcmp(e.path, "Y"))
            wrong++;
        looked++;
    }
    check(gs_thread_wait(id, NULL, NULL, __FILE__, __LINE__), "the reuser returned");
    gs_shm_lock();
    gs_shm_clear_fault(y);
    gs_shm_unlock();
    if (wrong) fprintf(stderr, "%ld of %ld lookups found the wrong entry\n", wrong, looked);
    check(looked > 0 && wrong == 0, "a lookup sees an entry whole");
    printf("lookups while an entry is reused for other sizes: each found the mapping\n");
}

/* Runs a contained worker that has to abort, and prints its message. */
static void expect_abort(void (*entry)(uint8_t *), handles h) {
    int64_t id = gs_thread_spawn(entry, &h, sizeof h, 1);
    uint8_t *msg;
    int64_t len;
    check(!gs_thread_wait(id, &msg, &len, __FILE__, __LINE__), "the worker aborted");
    check(msg != NULL, "the abort left a message");
    print_normalized("abort: ", msg, len, NULL);
    gs_free_msg(msg);
}

/* map_file refusing a path: the zero handle and the reason, of which the
   system's own wording is left out. */
static void refused(const char *path, int64_t pathlen, const char *what) {
    gs_att a;
    gs_shm_new(&a, __FILE__, __LINE__);
    gs_res m = 1;
    uint8_t *why = NULL;
    int64_t n = 0;
    check(!gs_shm_map_file(&a, (const uint8_t *)path, pathlen, &m, &why, &n, __FILE__, __LINE__),
          "map_file refuses");
    check(m == 0 && why != NULL && n > 0, "a refusal gives the zero handle and a reason");
    char text[1024];
    snprintf(text, sizeof text, "%.*s", (int)n, (const char *)why);
    char *reason = strstr(text, ": ");
    if (reason && !strstr(reason, "regular") && !strstr(reason, "NUL"))
        strcpy(reason, ": <the system's reason>");
    print_normalized(what, (const uint8_t *)text, (int64_t)strlen(text), NULL);
    gs_shm_reason_done();
    gs_shm_detach(&a);
}

#ifndef _WIN32
/* Runs f in a child whose stderr is captured, and prints how it ended and
   what it wrote, `num` written <n>. */
static void in_child(void (*f)(void), const char *what, const char *num) {
    int fds[2];
    check(pipe(fds) == 0, "make a pipe");
    fflush(NULL);
    pid_t pid = fork();
    check(pid >= 0, "fork");
    if (pid == 0) {
        dup2(fds[1], 2);
        close(fds[0]);
        f();
        _exit(0);
    }
    close(fds[1]);
    uint8_t buf[4096];
    size_t n = 0;
    for (;;) {
        ssize_t k = read(fds[0], buf + n, sizeof buf - n);
        if (k <= 0) break;
        n += (size_t)k;
    }
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    char lead[256];
    snprintf(lead, sizeof lead, "%s: exit %d: ", what, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    print_normalized(lead, buf, (int64_t)n, num);
}

static size_t page;
static char big[600];

/* Maps a file of four pages, cuts it to one through another descriptor, as
   another process would, and reads in the third. */
static void truncated(void) {
    gs_att a;
    gs_shm_new(&a, __FILE__, __LINE__);
    gs_res m = map(&a, big);
    const uint8_t *p = gs_shm_view(&a, m, 0, (int64_t)(4 * page), 1, 1, "u8", __FILE__,
                                   __LINE__);
    int fd = open(big, O_WRONLY);
    check(fd >= 0 && ftruncate(fd, (off_t)page) == 0, "truncate the mapped file");
    close(fd);
    volatile uint8_t x = p[2 * page];
    (void)x;
}

static void written(void) {
    gs_att a;
    gs_shm_new(&a, __FILE__, __LINE__);
    gs_res m = map(&a, col);
    uint8_t *p = (uint8_t *)gs_shm_view(&a, m, 0, 64, 8, 8, "i64", __FILE__, __LINE__);
    p[16] = 1;
}

/* Workers that make arenas, map files into them and release them, so
   adding and clearing the fault handlers' entries, while main's thread
   faults in a truncated file. */
static int churned;

static void churner(uint8_t *args) {
    (void)args;
    for (int i = 0; i < 100; i++) {
        gs_att a;
        gs_shm_new(&a, __FILE__, __LINE__);
        map(&a, col);
        map(&a, col);
        gs_shm_detach(&a);
        __atomic_fetch_add(&churned, 1, __ATOMIC_RELAXED);
    }
}

static void truncated_churning(void) {
    for (int i = 0; i < 4; i++) gs_thread_spawn(churner, NULL, 0, 0);
    while (__atomic_load_n(&churned, __ATOMIC_RELAXED) < 40) {}
    truncated();
}
#endif

static void check_baseline(long allocations, long mappings) {
    check(counter_add(&live_allocations, 0) == allocations,
          "every arena, region, path and hold released");
    check(counter_add(&live_mappings, 0) == mappings, "every mapping unmapped");
    check(gs_narenas == 0, "no arena left in the registry");
}

int main(void) {
    gs_rt_init(0, NULL, 1, 1, GS_MAX_STACKS);
    make_files();
#ifdef _WIN32
    /* A mapped file cannot be truncated on Windows at all: no other process
       may open it to write. The faults are what the POSIX children report. */
    {
        gs_att a;
        gs_shm_new(&a, __FILE__, __LINE__);
        map(&a, col);
        HANDLE f = CreateFileA(col, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
                               FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
        check(f == INVALID_HANDLE_VALUE, "a mapped file cannot be opened to write");
        gs_shm_detach(&a);
        gs_shm_release_held();
        const char *lead = "exit 1: goose runtime error: <dir>/big was truncated or could not be "
                           "read while mapped: a read at byte <n> faulted";
        printf("truncated: %s\n", lead);
        printf("truncated while workers map and release: %s\n", lead);
        printf("written: exit 1: goose runtime error: a write to <dir>/col.i64, which is mapped "
               "read-only, faulted at byte 16: a defect of the compiler or of C code\n");
    }
#else
    /* First, while this process has one thread, so that its children may
       start workers: a read past the end of a file truncated while it is
       mapped, also while other threads add and clear the fault handlers'
       entries, and a write to a mapping. */
    {
        page = (size_t)sysconf(_SC_PAGESIZE);
        snprintf(big, sizeof big, "%s/big", dir);
        uint8_t *bytes = (uint8_t *)calloc(4, page);
        char at[32];
        snprintf(at, sizeof at, "%llu", (unsigned long long)(2 * page));
        write_file(big, bytes, 4 * page);
        in_child(truncated, "truncated", at);
        write_file(big, bytes, 4 * page);
        in_child(truncated_churning, "truncated while workers map and release", at);
        free(bytes);
        in_child(written, "written", NULL);
        unlink(big);
    }
#endif
    /* The registry and the fault handlers' first chunk are the runtime's
       for good, made with the first arena and the first mapping, as are the
       records of the contained workers that aborted. */
    {
        gs_att a;
        gs_shm_new(&a, __FILE__, __LINE__);
        handles h = { gs_shm_handle(&a), map(&a, col) };
        uint8_t *msg;
        int64_t len;
        int64_t id = gs_thread_spawn(holder, &h, sizeof h, 1);
        check(!gs_thread_wait(id, &msg, &len, __FILE__, __LINE__), "the first holder aborted");
        gs_free_msg(msg);
        gs_shm_detach(&a);
        gs_shm_release_held();
    }
    long allocations = counter_add(&live_allocations, 0);
    long mappings = counter_add(&live_mappings, 0);

    /* Churn: arenas made and released with their files mapped, attached to
       twice, viewed, and the empty file. */
    for (int round = 0; round < 200; round++) {
        gs_att a, b;
        gs_shm_new(&a, __FILE__, __LINE__);
        gs_res m1 = map(&a, col), m2 = map(&a, col), m0 = map(&a, empty);
        check(m1 != m2, "two mappings, two handles");
        gs_shm_attach(&b, gs_shm_handle(&a), __FILE__, __LINE__);
        check(gs_shm_size(&b, m0, __FILE__, __LINE__) == 0, "an empty file maps with size 0");
        check(gs_shm_view(&b, m0, 0, 0, 8, 8, "i64", __FILE__, __LINE__) != NULL,
              "an empty view of an empty file");
        check(sum(gs_shm_view(&a, m1, 0, 64, 8, 8, "i64", __FILE__, __LINE__), 64) == 3 * 2016,
              "the first view reads the file");
        check(sum(gs_shm_view(&b, m2, 256, 32, 8, 8, "i64", __FILE__, __LINE__), 32) ==
                  3 * (32 * 32 + 496),
              "a view through another attachment");
        check(gs_shm_view(&b, m2, 512, 0, 8, 8, "i64", __FILE__, __LINE__) != NULL,
              "an empty view at the end");
        gs_shm_detach(&b);
        check(a.arena->count == 1, "the second attachment's end leaves the arena");
        gs_shm_detach(&a);
    }
    gs_shm_release_held();
    check_baseline(allocations, mappings);
    printf("churn: 200 arenas, 600 files mapped, all released\n");

    /* Files the system makes up as they are read: /proc's report no size,
       and sysfs's 4096 and will not map. Each is read to its end into
       memory of the runtime's, which its views read and its release frees.
       Linux only; elsewhere there are none, and the line is Linux's. */
#ifdef __linux__
    {
        static const char *made[] = { "/proc/version", "/sys/devices/system/cpu/online" };
        for (int i = 0; i < 2; i++) {
            FILE *f = fopen(made[i], "rb");
            if (!f) continue;
            static uint8_t want[1 << 16];
            size_t n = fread(want, 1, sizeof want, f);
            fclose(f);
            gs_att a;
            gs_shm_new(&a, __FILE__, __LINE__);
            gs_res m = map(&a, made[i]);
            int64_t size = gs_shm_size(&a, m, __FILE__, __LINE__);
            const uint8_t *p = gs_shm_view(&a, m, 0, size, 1, 1, "u8", __FILE__, __LINE__);
            check(n > 0 && size == (int64_t)n && !memcmp(p, want, n),
                  "a file the system makes up is read in whole");
            gs_shm_detach(&a);
        }
        gs_shm_release_held();
        check_baseline(allocations, mappings);
    }
#endif
    printf("files the system reports no size for, or will not map: read in whole\n");

    /* Workers attach through a handle and read one mapping at once; the last
       attachment, a worker's, releases it. */
    {
        gs_att a;
        gs_shm_new(&a, __FILE__, __LINE__);
        handles h = { gs_shm_handle(&a), map(&a, col) };
        int64_t ids[16];
        for (int round = 0; round < 8; round++) {
            for (int i = 0; i < 16; i++) ids[i] = gs_thread_spawn(viewer, &h, sizeof h, 0);
            for (int i = 0; i < 16; i++)
                check(gs_thread_wait(ids[i], NULL, NULL, __FILE__, __LINE__),
                      "the viewer returned");
        }
        check(a.arena->count == 1, "the workers' attachments ended");
        /* A contained worker that aborts holding attachments: its end ends
           them, before the wait returns. */
        expect_abort(holder, h);
        check(a.arena->count == 1, "the aborted worker's attachments ended");
        expect_abort(out_of_bounds, h);
        expect_abort(misaligned, h);
        expect_abort(zero_view, h);
        expect_abort(foreign, h);
        check(a.arena->count == 1, "the aborts ended their attachments");
        for (int i = 0; i < 3; i++) expect_abort(refused_then_full, h);
        int64_t id = gs_thread_spawn(last_holder, &h, sizeof h, 0);
        gs_mutex_lock(&test_mutex);
        while (!attached) gs_cond_wait(&test_cond, &test_mutex);
        gs_mutex_unlock(&test_mutex);
        gs_shm_detach(&a);
        check(gs_narenas == 1, "the worker's attachment keeps the arena");
        gs_mutex_lock(&test_mutex);
        main_detached = 1;
        gs_cond_broadcast(&test_cond);
        gs_mutex_unlock(&test_mutex);
        check(gs_thread_wait(id, NULL, NULL, __FILE__, __LINE__), "the last holder returned");
        gs_shm_release_held();
        check_baseline(allocations, mappings);
        printf("workers: 129 viewers and 8 aborts, all released\n");
        expect_abort(stale, h);
        h.arena = 0;
        expect_abort(stale, h);
    }

    lookups_during_reuse();
    refused(missing, (int64_t)strlen(missing), "refused a missing file: ");
    refused(dir, (int64_t)strlen(dir), "refused a directory: ");
    refused("col\0x", 5, "refused a path holding a NUL byte: ");
#ifdef _WIN32
    /* Windows has no FIFO a path names. */
    printf("refused a FIFO, without waiting for a writer: <dir>/fifo: not a regular file\n");
#else
    {
        char fifo[600];
        snprintf(fifo, sizeof fifo, "%s/fifo", dir);
        check(mkfifo(fifo, 0600) == 0, "make a FIFO");
        refused(fifo, (int64_t)strlen(fifo), "refused a FIFO, without waiting for a writer: ");
        unlink(fifo);
    }
#endif
    gs_shm_release_held();
    check_baseline(allocations, mappings);

    /* Last: the serials are used up after this. */
    handles none = { 0, 0 };
    expect_abort(too_many_regions, none);
    expect_abort(serials, none);
    check_baseline(allocations, mappings);
#ifdef _WIN32
    DeleteFileA(col);
    DeleteFileA(empty);
    RemoveDirectoryA(dir);
#else
    unlink(col);
    unlink(empty);
    rmdir(dir);
#endif
    printf("done\n");
    return 0;
}
