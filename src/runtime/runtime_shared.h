/* Goose runtime — shared memory (§11.4, docs/design/shared_memory.md), as
   runtime.h declares it: the arenas, the attachments that count them, the
   files mapped into them and the arrays frozen into them, which every
   thread attached to an arena reads in place; and the dynamic stacks those
   arrays are built on, each alone on a slot of one reservation, the
   dynamic budget. Follows runtime_threads.h. Like the queues, an arena is
   runtime memory outside every data stack.

   The registry holds every arena that has an attachment left, by serial,
   under one lock, which also guards each arena's table of regions and the
   slots' free list: attach looks a serial up under it, and map_file and
   freeze append a region under it, their system calls made outside it. A
   view takes it only for a region its attachment has not looked up yet.
   The count of attachments is atomic, with acquire-release order, so that
   whoever ends the last attachment and releases the arena sees every view
   of it done. Without threads there is one thread, and neither a lock nor
   atomics. */

#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif
#endif

/* The most serials and regions a handle's bits hold: the 2^40-th arena and
   the 2^24-th region of one arena abort. A test sets them lower. */
#ifndef GS_SHM_MAX_SERIAL
#define GS_SHM_MAX_SERIAL ((1ull << GS_RES_SERIAL_BITS) - 1)
#endif
#ifndef GS_SHM_MAX_REGIONS
#define GS_SHM_MAX_REGIONS ((1ll << GS_RES_REGION_BITS) - 1)
#endif
/* The size past which no value lies (§10.4). */
#define GS_SHM_MAX_FILE ((int64_t)1 << 48)

#if GS_NEED_THREADS
static gs_mutex gs_shm_mutex = GS_MUTEX_INIT;
#define gs_shm_lock() gs_mutex_lock(&gs_shm_mutex)
#define gs_shm_unlock() gs_mutex_unlock(&gs_shm_mutex)
#ifndef __ATOMIC_ACQ_REL
#define __ATOMIC_ACQ_REL 4
#endif
#if defined(_MSC_VER) && !defined(__clang__)
#define gs_shm_count(p, n) InterlockedExchangeAdd64((volatile LONG64 *)(p), (n))
#else
#define gs_shm_count(p, n) __atomic_fetch_add((p), (n), __ATOMIC_ACQ_REL)
#endif
#else
#define gs_shm_lock() ((void)0)
#define gs_shm_unlock() ((void)0)
static int64_t gs_shm_count_(int64_t *p, int64_t n) {
    int64_t old = *p;
    *p = old + n;
    return old;
}
#define gs_shm_count(p, n) gs_shm_count_((p), (n))
#endif

/* A region of an arena: a mapped file, or one read into memory of the
   runtime's own where the system does not map it; or a frozen array, of
   `elemsize`-byte elements, on the slot that was its dynamic stack's. An
   empty file maps no memory, and an empty array takes no slot; each is a
   view's base all the same. */
typedef struct {
    const uint8_t *base;
    int64_t len;
    char *path;                 /* NUL-terminated, as the program gave it. */
    void *mem;                  /* What to unmap; NULL for an empty file. */
    size_t memlen;
    int copied;                 /* Read into anonymous memory, not mapped. */
    int64_t fault;              /* Its entry for the fault handlers, or -1. */
    int64_t elemsize;           /* A frozen array's element size; 0 for a mapping. */
    int64_t slot;               /* A frozen array's slot, or -1. */
#ifdef _WIN32
    HANDLE file, mapping;
#endif
} gs_shm_region;

struct gs_arena {
    uint64_t serial;
    int64_t count;              /* Attachments; atomic. */
    gs_shm_region *regions;     /* 1 .. nregions; under the lock. */
    int64_t nregions, capregions;
};

static const uint8_t gs_shm_empty[1];

/* Under the lock: the arenas that have attachments, the next serial, and
   what GS_SHARED_STATS reports. */
static struct gs_arena **gs_arenas;
static int64_t gs_narenas, gs_caparenas;
static uint64_t gs_shm_next = 1;
static int64_t gs_shm_made, gs_shm_released, gs_shm_mapped, gs_shm_unmapped;
static int64_t gs_dyn_opened, gs_dyn_closed, gs_dyn_frozen, gs_dyn_thawed;
static int64_t gs_dyn_fresh, gs_dyn_reused;

/* The calling thread's attachments and dynamic stacks, innermost last: a
   declaration pushes its arena or its slot, a freeze swaps the slot, and
   its ends pop it (they nest, as scopes do), and after a contained worker's
   abort, which skips the ends, gs_shm_release_held ends the rest. Runtime
   memory, not the frames the declarations lie in, which an abort leaves
   behind. */
typedef struct {
    struct gs_arena *arena;     /* An attachment's; NULL for a dynamic stack. */
    int64_t slot;               /* A dynamic stack's slot; -1 for an attachment. */
} gs_shm_holding;
static GS_TLS gs_shm_holding *gs_shm_held;
static GS_TLS int64_t gs_shm_nheld, gs_shm_capheld;

static void gs_shm_hold(struct gs_arena *a, int64_t slot) {
    if (gs_shm_nheld == gs_shm_capheld) {
        int64_t cap = gs_shm_capheld ? gs_shm_capheld * 2 : 8;
        gs_shm_holding *p = (gs_shm_holding *)realloc(gs_shm_held, (size_t)cap * sizeof(*p));
        if (!p) gs_panic("out of memory holding a shared arena or a dynamic stack");
        gs_shm_held = p;
        gs_shm_capheld = cap;
    }
    gs_shm_held[gs_shm_nheld].arena = a;
    gs_shm_held[gs_shm_nheld].slot = slot;
    gs_shm_nheld++;
}

/* n in decimal, its digits in groups of three, in buf. */
static void gs_shm_thousands(char *buf, int64_t n) {
    char d[32];
    int k = snprintf(d, sizeof d, "%lld", (long long)n), j = 0;
    for (int i = 0; i < k; i++) {
        if (i && (k - i) % 3 == 0) buf[j++] = ',';
        buf[j++] = d[i];
    }
    buf[j] = 0;
}

/* The fault handlers' entry for a mapping (runtime_impl.h), under the lock:
   a cleared one again, else a new one. */
static int64_t gs_shm_add_fault(const uint8_t *base, size_t len, const char *path) {
    uintptr_t i = 0, n = gs_word_load(&gs_nmapents);
    for (; i < n; i++) {
        gs_mapent *c = (gs_mapent *)gs_word_load(&gs_mapchunks[i / GS_MAPCHUNK]);
        if (!gs_word_load(&c[i % GS_MAPCHUNK].base)) break;
    }
    if (i >= (uintptr_t)GS_MAPCHUNK * GS_MAPCHUNKS) return -1;
    gs_mapent *c = (gs_mapent *)gs_word_load(&gs_mapchunks[i / GS_MAPCHUNK]);
    if (!c) {
        c = (gs_mapent *)calloc(GS_MAPCHUNK, sizeof(gs_mapent));
        if (!c) return -1;
        gs_word_store(&gs_mapchunks[i / GS_MAPCHUNK], (uintptr_t)c);
    }
    gs_mapent_set(&c[i % GS_MAPCHUNK], (uintptr_t)base, (uintptr_t)len, path);
    if (i == n) gs_word_store(&gs_nmapents, n + 1);
    return (int64_t)i;
}

/* Before the mapping goes, under the lock: no lookup takes the entry once
   it is cleared, nor while it is. */
static void gs_shm_clear_fault(int64_t i) {
    if (i < 0) return;
    gs_mapent *c = (gs_mapent *)gs_word_load(&gs_mapchunks[i / GS_MAPCHUNK]);
    gs_mapent_set(&c[i % GS_MAPCHUNK], 0, 0, NULL);
}

/* What a region holds of the system's, given back. */
static void gs_shm_unmap(gs_shm_region *r) {
#ifdef _WIN32
    if (r->mem && !r->copied) UnmapViewOfFile(r->mem);
    else if (r->mem) VirtualFree(r->mem, 0, MEM_RELEASE);
    if (r->mapping) CloseHandle(r->mapping);
    if (r->file && r->file != INVALID_HANDLE_VALUE) CloseHandle(r->file);
#else
    if (r->mem) munmap(r->mem, r->memlen);
#endif
    free(r->path);
}

/* ---------------------------------------------------------------------------
   The dynamic budget (§11.4): one reservation of N slots, each of R usable
   bytes, a data stack's reservation (GS_STACK_RESERVE), and a guard gap of
   G (GS_STACK_GAP), where N is what B (GS_DYNAMIC_BUDGET) holds beside the
   slots' records, N * (R + G) + H <= B. The first dynamic stack reserves it,
   inaccessible; a slot is opened read-write as a dynamic stack first takes
   it (on Windows its pages are committed on touch, as a data stack's are).
   A slot is fresh, live (a dynamic stack's), frozen (a region of an arena)
   or free, its pages kept: a dynamic stack takes a free slot before a fresh
   one, so arenas built and dropped over and over fault no pages after the
   first round, and no slot is unmapped while the program runs, which keeps
   every slot of the budget for reuse. trim_memory() gives the free slots'
   pages back. The lock guards the free list, the count of slots opened, and
   each slot's state, which the fault handlers read as words
   (runtime_impl.h). */

#define GS_SLOT_HUGE_MIN (2u << 20)

static uint8_t *gs_slot_base(int64_t i) {
    return (uint8_t *)(gs_dynbase + (uintptr_t)i * gs_dynstride);
}

/* Under the lock, by the first dynamic stack: the reservation. Where the
   platform refuses it, half as many slots, down to one. */
static int64_t gs_dynnext;          /* Slots below it have been opened. */
static int64_t gs_dynfree = -1;     /* The free list, latest first. */

static void *gs_slots_os_reserve(size_t size) {
#ifdef _WIN32
    return VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_READWRITE);
#else
    void *p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS
                   #ifdef MAP_NORESERVE
                       | MAP_NORESERVE
                   #endif
                   , -1, 0);
    return p == MAP_FAILED ? NULL : p;
#endif
}

static int gs_slots_reserve(void) {
    if (gs_dynbase) return 1;
    uint64_t stride = (uint64_t)gs_region_reserve + (uint64_t)gs_region_gap;
    uint64_t n = stride ? gs_dynbudget / stride : 0;
    while (n && n * (stride + sizeof(gs_slot)) > gs_dynbudget) n--;
    if (!n) return 0;
    void *p = NULL;
    for (;;) {
        p = gs_slots_os_reserve((size_t)(n * stride));
        if (p) break;
        if (n == 1) gs_panic("cannot reserve address space for a dynamic stack's slot");
        n /= 2;
    }
    gs_dynslots = (gs_slot *)calloc((size_t)n, sizeof(gs_slot));
    if (!gs_dynslots) gs_panic("out of memory reserving the dynamic stacks' slots");
    for (uint64_t i = 0; i < n; i++) gs_dynslots[i].next = -1;
    gs_dynn = (uintptr_t)n;
    gs_dynstride = (uintptr_t)stride;
    gs_dynusable = (uintptr_t)gs_region_reserve;
    gs_word_store(&gs_dynbase, (uintptr_t)p);
    return 1;
}

/* Opens fresh slot i read-write, which no other thread can reach yet. */
static void gs_slot_open(int64_t i) {
    uint8_t *base = gs_slot_base(i);
#ifdef _WIN32
    gs_word_store(&gs_dynslots[i].committed, (uintptr_t)base);
#else
    if (mprotect(base, gs_dynusable, PROT_READ | PROT_WRITE))
        gs_panic("cannot open a dynamic stack's slot: the system refused its memory");
    /* As for a data stack (gs_os_reserve): most hold a few bytes, which a
       transparent huge page at the start would commit 2 MB for. Past those
       2 MB a slot holds a large array, which other threads read at random
       once it is frozen: huge pages there made the join's probe 17%
       faster (bench/shared_memory/join.goose), where the system gives
       them only to memory that asks. */
    #ifdef MADV_NOHUGEPAGE
        madvise(base, gs_dynusable < GS_SLOT_HUGE_MIN ? gs_dynusable : GS_SLOT_HUGE_MIN,
                MADV_NOHUGEPAGE);
    #endif
    #ifdef MADV_HUGEPAGE
        if (gs_dynusable > GS_SLOT_HUGE_MIN)
            madvise(base + GS_SLOT_HUGE_MIN, gs_dynusable - GS_SLOT_HUGE_MIN, MADV_HUGEPAGE);
    #endif
#endif
}

/* Under the lock: a free slot, else a fresh one, which *open says the
   caller opens (gs_slot_open) once the lock is let go; -1 where all N are
   live or frozen. */
static int64_t gs_slot_take(int *open) {
    *open = 0;
    int64_t i = gs_dynfree;
    if (i >= 0) {
        gs_dynfree = gs_dynslots[i].next;
        gs_dynslots[i].next = -1;
        gs_dynslots[i].trimmed = 0;
        gs_dyn_reused++;
        return i;
    }
    if (gs_dynnext >= (int64_t)gs_dynn) return -1;
    *open = 1;
    gs_dyn_fresh++;
    return gs_dynnext++;
}

/* Under the lock: slot i on the free list, its pages kept. */
static void gs_slot_free(int64_t i) {
    gs_slot *s = &gs_dynslots[i];
    gs_word_store(&s->state, GS_SLOT_FREE);
    s->next = gs_dynfree;
    gs_dynfree = i;
}

/* Slot i, now its dynamic stack's, declared at file:line. */
static void gs_slot_live(int64_t i, const char *file, int line) {
    gs_slot *s = &gs_dynslots[i];
    gs_word_store(&s->file, (uintptr_t)file);
    gs_word_store(&s->line, (uintptr_t)line);
    gs_word_store(&s->state, GS_SLOT_LIVE);
}

/* A frozen slot's protection, a debug build's: read-only, or read-write
   again as its arena goes. On Windows only the committed pages, which are
   all its array wrote; past them nothing is committed, and a write faults
   all the same. */
static void gs_slot_protect(int64_t i, int readonly) {
    uint8_t *base = gs_slot_base(i);
#ifdef _WIN32
    uintptr_t end = gs_word_load(&gs_dynslots[i].committed);
    DWORD old;
    if (end > (uintptr_t)base &&
        !VirtualProtect(base, (size_t)(end - (uintptr_t)base),
                        readonly ? PAGE_READONLY : PAGE_READWRITE, &old))
        gs_panic("cannot protect a frozen region");
#else
    if (mprotect(base, gs_dynusable, readonly ? PROT_READ : PROT_READ | PROT_WRITE))
        gs_panic("cannot protect a frozen region");
#endif
}

/* The abort where every slot is live or frozen: the budget, the slot's
   sizes, the count and what raises it. */
static GS_NORETURN void gs_slots_full(const char *file, int line) {
    char b[40], r[40], g[40], n[32];
    *gs_size(b, gs_dynbudget) = 0;
    *gs_size(r, gs_region_reserve) = 0;
    *gs_size(g, gs_region_gap) = 0;
    gs_shm_thousands(n, (int64_t)gs_dynn);
    if (!gs_dynn)
        gs_failf(file, line, "the dynamic budget of %s holds no slot of %s and a %s gap, which "
                 "a dynamic stack takes; --dynamic-budget or -DGS_DYNAMIC_BUDGET raises it",
                 b, r, g);
    gs_failf(file, line, "every slot of the dynamic budget is in use, live or frozen: %s slot%s "
             "of %s and a %s gap each, in %s; --dynamic-budget or -DGS_DYNAMIC_BUDGET raises it",
             n, gs_dynn == 1 ? "" : "s", r, g, b);
}

/* The free slots' pages, given back (trim_memory, runtime_impl.h): the
   slots stay reserved and open, and the next owner of one faults in fresh
   pages. 0 where the system refused. */
static int gs_slots_trim(void) {
    int ok = 1;
    gs_shm_lock();
    for (int64_t i = gs_dynfree; i >= 0; i = gs_dynslots[i].next) {
        gs_slot *s = &gs_dynslots[i];
        if (s->trimmed) continue;
        uint8_t *base = gs_slot_base(i);
#ifdef _WIN32
        uintptr_t end = gs_word_load(&s->committed);
        if (end > (uintptr_t)base) {
            if (VirtualFree(base, (size_t)(end - (uintptr_t)base), MEM_DECOMMIT))
                gs_word_store(&s->committed, (uintptr_t)base);
            else
                ok = 0;
        }
#elif defined(__APPLE__)
        if (mmap(base, gs_dynusable, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED)
            ok = 0;
#else
        if (madvise(base, gs_dynusable, MADV_DONTNEED)) ok = 0;
#endif
        s->trimmed = 1;
    }
    gs_shm_unlock();
    return ok;
}

/* The arena whose last attachment just ended: out of the registry, so that
   no attach finds it, its frozen slots free, its files unmapped, then gone.
   No attachment is left, so no view either, and its regions are this
   thread's alone: a debug build's protection comes off before the lock is
   taken. */
static void gs_shm_release(struct gs_arena *a) {
    for (int64_t i = 1; i <= a->nregions; i++)
        if (a->regions[i].slot >= 0 && gs_dynslots[a->regions[i].slot].protect) {
            gs_slot_protect(a->regions[i].slot, 0);
            gs_dynslots[a->regions[i].slot].protect = 0;
        }
    gs_shm_lock();
    for (int64_t i = 0; i < gs_narenas; i++)
        if (gs_arenas[i] == a) {
            gs_arenas[i] = gs_arenas[--gs_narenas];
            break;
        }
    for (int64_t i = 1; i <= a->nregions; i++) {
        gs_shm_region *r = &a->regions[i];
        if (r->elemsize) {
            if (r->slot >= 0) gs_slot_free(r->slot);
            gs_dyn_thawed++;
        } else {
            gs_shm_clear_fault(r->fault);
            gs_shm_unmapped++;
        }
    }
    gs_shm_released++;
    gs_shm_unlock();
    for (int64_t i = 1; i <= a->nregions; i++)
        if (!a->regions[i].elemsize) gs_shm_unmap(&a->regions[i]);
    free(a->regions);
    free(a);
}

/* One attachment of a fewer: the arena's release at the last. */
static void gs_shm_end(struct gs_arena *a) {
    if (gs_shm_count(&a->count, -1) == 1) gs_shm_release(a);
}

GS_API void gs_shm_new(gs_att *att, const char *file, int line) {
    struct gs_arena *a = (struct gs_arena *)calloc(1, sizeof(struct gs_arena));
    if (!a) gs_panic("out of memory making a shared arena");
    a->count = 1;
    gs_shm_lock();
    if (gs_shm_next > GS_SHM_MAX_SERIAL) {
        gs_shm_unlock();
        free(a);
        gs_failf(file, line, "shared arena serials are used up: %llu arenas were made",
                 (unsigned long long)GS_SHM_MAX_SERIAL);
    }
    if (gs_narenas == gs_caparenas) {
        int64_t cap = gs_caparenas ? gs_caparenas * 2 : 16;
        struct gs_arena **p =
            (struct gs_arena **)realloc(gs_arenas, (size_t)cap * sizeof(*p));
        if (!p) gs_panic("out of memory making a shared arena");
        gs_arenas = p;
        gs_caparenas = cap;
    }
    a->serial = gs_shm_next++;
    gs_arenas[gs_narenas++] = a;
    gs_shm_made++;
    gs_shm_unlock();
    gs_shm_hold(a, -1);
    att->arena = a;
    att->res = 0;
    att->base = NULL;
    att->len = 0;
}

GS_API void gs_shm_attach(gs_att *att, gs_res h, const char *file, int line) {
    if (!h) gs_failf(file, line, "attach of the zero handle, which names no shared arena");
    if (h & (((uint64_t)1 << GS_RES_REGION_BITS) - 1))
        gs_panic("attach of a handle that names a region, not an arena");
    uint64_t serial = h >> GS_RES_REGION_BITS;
    struct gs_arena *a = NULL;
    gs_shm_lock();
    for (int64_t i = 0; i < gs_narenas; i++)
        if (gs_arenas[i]->serial == serial) {
            a = gs_arenas[i];
            /* An arena whose last attachment ended and which is not out of
               the registry yet is released all the same. */
            if (gs_shm_count(&a->count, 1) == 0) {
                gs_shm_count(&a->count, -1);
                a = NULL;
            }
            break;
        }
    gs_shm_unlock();
    if (!a)
        gs_failf(file, line, "attach of a released shared arena: it was released when its "
                             "last attachment ended");
    gs_shm_hold(a, -1);
    att->arena = a;
    att->res = 0;
    att->base = NULL;
    att->len = 0;
}

GS_API void gs_shm_detach(gs_att *att) {
    struct gs_arena *a = att->arena;
    if (!gs_shm_nheld || gs_shm_held[gs_shm_nheld - 1].arena != a)
        gs_panic("shared arena attachments and dynamic stacks ended out of order");
    gs_shm_nheld--;
    att->arena = NULL;
    att->res = 0;
    gs_shm_end(a);
}

/* An unfrozen slot's dynamic stack ended: the slot free, its pages kept. */
static void gs_dstack_end(int64_t slot) {
    gs_shm_lock();
    gs_slot_free(slot);
    gs_dyn_closed++;
    gs_shm_unlock();
}

GS_API void gs_shm_release_held(void) {
    while (gs_shm_nheld) {
        gs_shm_holding h = gs_shm_held[--gs_shm_nheld];
        if (h.arena) gs_shm_end(h.arena);
        else gs_dstack_end(h.slot);
    }
    free(gs_shm_held);
    gs_shm_held = NULL;
    gs_shm_capheld = 0;
    gs_shm_reason_done();
}

GS_API gs_res gs_shm_handle(const gs_att *att) {
    return (gs_res)(att->arena->serial << GS_RES_REGION_BITS);
}

/* A slot for a dynamic stack declared at file:line, taken under the lock
   and opened outside it; or the abort where none is left. The first
   reserves the budget. */
static int64_t gs_dstack_slot(const char *file, int line) {
    int open = 0;
    gs_shm_lock();
    int64_t i = gs_slots_reserve() ? gs_slot_take(&open) : -1;
    gs_shm_unlock();
    if (i < 0) gs_slots_full(file, line);
    if (open) gs_slot_open(i);
    gs_slot_live(i, file, line);
    return i;
}

GS_API void gs_dstack_open(gs_dstack *d, const char *file, int line) {
    int64_t i = gs_dstack_slot(file, line);
    gs_shm_hold(NULL, i);
    gs_shm_lock();
    gs_dyn_opened++;
    gs_shm_unlock();
    d->slot = i;
    d->stack.top = gs_slot_base(i);
}

GS_API void gs_dstack_close(gs_dstack *d) {
    if (!gs_shm_nheld || gs_shm_held[gs_shm_nheld - 1].arena ||
        gs_shm_held[gs_shm_nheld - 1].slot != d->slot)
        gs_panic("shared arena attachments and dynamic stacks ended out of order");
    gs_shm_nheld--;
    gs_dstack_end(d->slot);
    d->slot = -1;
}

GS_API gs_res gs_shm_freeze(gs_att *att, gs_dstack *d, int64_t count, int64_t size, int protect,
                            const char *file, int line) {
    struct gs_arena *a = att->arena;
    int64_t old = d->slot, bytes = count * size;
    gs_shm_region r;
    memset(&r, 0, sizeof r);
    r.fault = -1;
    r.elemsize = size;
    r.slot = bytes ? old : -1;
    r.base = bytes ? gs_slot_base(old) : gs_shm_empty;
    r.len = bytes;
    int64_t fresh = -1;
    int open = 0;
    gs_shm_lock();
    if (a->nregions >= GS_SHM_MAX_REGIONS) {
        gs_shm_unlock();
        char most[32];
        gs_shm_thousands(most, GS_SHM_MAX_REGIONS);
        gs_failf(file, line, "a shared arena holds at most %s regions", most);
    }
    /* Taken first, so that an abort for want of one changes nothing. */
    if (bytes && (fresh = gs_slot_take(&open)) < 0) {
        gs_shm_unlock();
        gs_slots_full(file, line);
    }
    if (a->nregions + 1 >= a->capregions) {
        int64_t cap = a->capregions ? a->capregions * 2 : 8;
        gs_shm_region *p = (gs_shm_region *)realloc(a->regions, (size_t)cap * sizeof(*p));
        if (!p) gs_panic("out of memory freezing an array");
        a->regions = p;
        a->capregions = cap;
    }
    if (bytes) {
        gs_word_store(&gs_dynslots[old].state, GS_SLOT_FROZEN);
        gs_dynslots[old].protect = protect != 0;
    }
    a->regions[++a->nregions] = r;
    gs_res h = (gs_res)(a->serial << GS_RES_REGION_BITS | (uint64_t)a->nregions);
    gs_dyn_frozen++;
    gs_shm_unlock();
    if (!bytes) return h;
    /* The region is the arena's, which this attachment keeps, so it stays
       while its protection goes on. */
    if (protect) gs_slot_protect(old, 1);
    if (open) gs_slot_open(fresh);
    gs_slot_live(fresh, (const char *)gs_word_load(&gs_dynslots[old].file),
                 (int)gs_word_load(&gs_dynslots[old].line));
    for (int64_t k = gs_shm_nheld - 1; k >= 0; k--)
        if (!gs_shm_held[k].arena && gs_shm_held[k].slot == old) {
            gs_shm_held[k].slot = fresh;
            break;
        }
    d->slot = fresh;
    d->stack.top = gs_slot_base(fresh);
    return h;
}

/* Whether serial names an arena that has an attachment left, which a view
   of one of its regions through another arena's attachment tells from one
   released (a region used after its release). */
static int gs_shm_live(uint64_t serial) {
    int live = 0;
    gs_shm_lock();
    for (int64_t i = 0; i < gs_narenas && !live; i++) live = gs_arenas[i]->serial == serial;
    gs_shm_unlock();
    return live;
}

GS_API void gs_shm_frozen_slow(gs_att *att, gs_res m, int64_t size, const char *file,
                               int line) {
    struct gs_arena *a = att->arena;
    if (!m) gs_failf(file, line, "view of the zero handle, which names no frozen array");
    if (m >> GS_RES_REGION_BITS != a->serial)
        gs_failf(file, line, gs_shm_live(m >> GS_RES_REGION_BITS)
                                 ? "view of a frozen array of another shared arena than the "
                                   "attachment's"
                                 : "view of a frozen array of a released shared arena: it was "
                                   "released when its last attachment ended");
    int64_t i = (int64_t)(m & (((uint64_t)1 << GS_RES_REGION_BITS) - 1));
    gs_shm_lock();
    if (i < 1 || i > a->nregions) {
        gs_shm_unlock();
        gs_panic("a handle names a region past its shared arena's count");
    }
    gs_shm_region *r = &a->regions[i];
    if (r->elemsize != size) {
        gs_shm_unlock();
        gs_panic("a frozen array's handle names a region of another kind");
    }
    att->res = m;
    att->base = r->base;
    att->len = r->len;
    gs_shm_unlock();
}

/* A failed map_file's reason, for `why`: "<path>: <what>", kept as the
   thread's pending reason, which the program appends and then lets go of
   (gs_shm_reason_done). An append can abort, a `why` of no room left
   aborting it, and a contained worker's abort skips the rest: so the
   runtime, not the frame, holds the reason, and a worker's end frees it. */
static GS_TLS uint8_t *gs_shm_reason;

GS_API void gs_shm_reason_done(void) {
    free(gs_shm_reason);
    gs_shm_reason = NULL;
}

static uint8_t gs_shm_refuse(uint8_t **why, int64_t *whylen, const char *path,
                             const char *what) {
    if (why) {
        size_t n = strlen(path) + strlen(what) + 2;
        uint8_t *s = (uint8_t *)malloc(n + 1);
        if (!s) gs_panic("out of memory reporting why a file was not mapped");
        snprintf((char *)s, n + 1, "%s: %s", path, what);
        gs_shm_reason_done();
        gs_shm_reason = s;
        *why = s;
        *whylen = (int64_t)n;
    }
    return 0;
}

#ifdef _WIN32
/* The text of a Windows error code, as UTF-8, in buf. */
static const char *gs_shm_winerror(DWORD e, char *buf, size_t n) {
    wchar_t w[512];
    DWORD k = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
                             e, 0, w, 512, NULL);
    while (k && (w[k - 1] == L'\n' || w[k - 1] == L'\r' || w[k - 1] == L'.')) k--;
    int m = k ? WideCharToMultiByte(CP_UTF8, 0, w, (int)k, buf, (int)n - 1, NULL, NULL) : 0;
    if (m <= 0) snprintf(buf, n, "Windows error %lu", (unsigned long)e);
    else buf[m] = 0;
    return buf;
}
#endif

/* Reads a file to its end into memory of the runtime's own, made read-only
   (§11.4), where the system will not map it, or reports no size for it
   though it has bytes, as /proc's and sysfs's files do: its region, or 0
   with errno set. A size the system reports (`hint`) is where the memory
   starts, and the end of the file is where the bytes do: a sysfs file says
   4096 and holds what it holds. A file that is empty is the empty region,
   and takes no memory. */
#ifndef _WIN32
static int gs_shm_copy_in(int fd, int64_t hint, gs_shm_region *r) {
    uint8_t first[4096];
    ssize_t k;
    while ((k = read(fd, first, sizeof first)) < 0 && errno == EINTR) {}
    if (k < 0) return 0;
    if (k == 0) {
        r->base = gs_shm_empty;
        r->len = 0;
        return 1;
    }
    size_t page = gs_page_size ? gs_page_size : 4096;
    size_t cap = (size_t)(hint > k ? hint : k);
    cap = (cap + page - 1) / page * page;
    uint8_t *p = (uint8_t *)mmap(NULL, cap, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
                                 -1, 0);
    if (p == (uint8_t *)MAP_FAILED) return 0;
    memcpy(p, first, (size_t)k);
    int64_t got = k;
    for (;;) {
        if ((size_t)got == cap) {
            if (got >= GS_SHM_MAX_FILE) {
                munmap(p, cap);
                errno = EFBIG;
                return 0;
            }
            uint8_t *q = (uint8_t *)mmap(NULL, cap * 2, PROT_READ | PROT_WRITE,
                                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (q == (uint8_t *)MAP_FAILED) {
                munmap(p, cap);
                return 0;
            }
            memcpy(q, p, cap);
            munmap(p, cap);
            p = q;
            cap *= 2;
        }
        k = read(fd, p + got, cap - (size_t)got);
        if (k < 0 && errno == EINTR) continue;
        if (k < 0) {
            int e = errno;
            munmap(p, cap);
            errno = e;
            return 0;
        }
        if (k == 0) break;
        got += k;
    }
    mprotect(p, cap, PROT_READ);
    r->mem = p;
    r->memlen = cap;
    r->base = p;
    r->len = got;
    r->copied = 1;
    return 1;
}
#endif

GS_API uint8_t gs_shm_map_file(gs_att *att, const uint8_t *path, int64_t pathlen, gs_res *m,
                               uint8_t **why, int64_t *whylen, const char *file, int line) {
    *m = 0;
    if (why) {
        *why = NULL;
        *whylen = 0;
    }
    if (!gs_is_le()) gs_abort(GS_E_ENDIAN, file, line);
    gs_shm_region r;
    memset(&r, 0, sizeof r);
    r.fault = -1;
    r.slot = -1;
    r.path = (char *)malloc((size_t)pathlen + 1);
    if (!r.path) gs_panic("out of memory mapping a file");
    if (pathlen) memcpy(r.path, path, (size_t)pathlen);
    r.path[pathlen] = 0;
    uint8_t refused;
    if (pathlen && memchr(path, 0, (size_t)pathlen)) {
        refused = gs_shm_refuse(why, whylen, r.path, "the path holds a NUL byte");
        free(r.path);
        return refused;
    }
#ifdef _WIN32
    char err[600];
    int wn = pathlen ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, r.path, (int)pathlen,
                                           NULL, 0) : 0;
    wchar_t *w = (wchar_t *)malloc(((size_t)wn + 1) * sizeof(wchar_t));
    if (!w) gs_panic("out of memory mapping a file");
    if ((pathlen && !wn) ||
        (wn && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, r.path, (int)pathlen, w, wn) != wn)) {
        free(w);
        refused = gs_shm_refuse(why, whylen, r.path, "the path is not UTF-8");
        free(r.path);
        return refused;
    }
    w[wn] = 0;
    /* Without FILE_SHARE_WRITE no other process opens the file to write
       while it is mapped, and a mapped file cannot be truncated; renames and
       deletes still work. */
    r.file = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    LARGE_INTEGER size;
    const char *what = NULL;
    if (r.file == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError(), attrs = GetFileAttributesW(w);
        r.file = NULL;
        what = attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)
                   ? "a directory, not a regular file"
                   : gs_shm_winerror(e, err, sizeof err);
    } else if (GetFileType(r.file) != FILE_TYPE_DISK) {
        what = "not a regular file";
    } else if (!GetFileSizeEx(r.file, &size)) {
        what = gs_shm_winerror(GetLastError(), err, sizeof err);
    } else if (size.QuadPart > GS_SHM_MAX_FILE) {
        what = "larger than 2^48 bytes, the most any value holds";
    } else if (size.QuadPart == 0) {
        CloseHandle(r.file);
        r.file = NULL;
        r.base = gs_shm_empty;
    } else {
        r.mapping = CreateFileMappingW(r.file, NULL, PAGE_READONLY, 0, 0, NULL);
        r.mem = r.mapping ? MapViewOfFile(r.mapping, FILE_MAP_READ, 0, 0, 0) : NULL;
        if (!r.mem) what = gs_shm_winerror(GetLastError(), err, sizeof err);
        r.base = (const uint8_t *)r.mem;
        r.len = size.QuadPart;
        r.memlen = (size_t)size.QuadPart;
    }
    free(w);
    if (what) {
        refused = gs_shm_refuse(why, whylen, r.path, what);
        gs_shm_unmap(&r);
        return refused;
    }
#else
    /* Not blocking where the path is a FIFO, which is refused below, as
       an open of one would wait for a writer. */
    const char *what = NULL;
    int fd = open(r.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    struct stat st;
    if (fd < 0) {
        what = strerror(errno);
    } else if (fstat(fd, &st)) {
        what = strerror(errno);
    } else if (S_ISDIR(st.st_mode)) {
        what = "a directory, not a regular file";
    } else if (!S_ISREG(st.st_mode)) {
        what = "not a regular file";
    } else if ((int64_t)st.st_size > GS_SHM_MAX_FILE) {
        what = "larger than 2^48 bytes, the most any value holds";
    } else if (st.st_size == 0) {
        /* Empty, or a file the system makes up as it is read (/proc). */
        if (!gs_shm_copy_in(fd, 0, &r)) what = strerror(errno);
    } else {
        void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
        if (p != MAP_FAILED) {
            r.mem = p;
            r.memlen = (size_t)st.st_size;
            r.base = (const uint8_t *)p;
            r.len = (int64_t)st.st_size;
        } else if (errno == ENODEV || errno == EINVAL) {
            /* A file system without mmap (sysfs, some network ones). */
            if (!gs_shm_copy_in(fd, (int64_t)st.st_size, &r)) what = strerror(errno);
        } else {
            what = strerror(errno);
        }
    }
    if (fd >= 0) close(fd);
    if (what) {
        refused = gs_shm_refuse(why, whylen, r.path, what);
        free(r.path);
        return refused;
    }
#endif
    struct gs_arena *a = att->arena;
    gs_shm_lock();
    if (a->nregions >= GS_SHM_MAX_REGIONS) {
        gs_shm_unlock();
        gs_shm_unmap(&r);
        char most[32];
        gs_shm_thousands(most, GS_SHM_MAX_REGIONS);
        gs_failf(file, line, "a shared arena holds at most %s regions", most);
    }
    if (a->nregions + 1 >= a->capregions) {
        int64_t cap = a->capregions ? a->capregions * 2 : 8;
        gs_shm_region *p = (gs_shm_region *)realloc(a->regions, (size_t)cap * sizeof(*p));
        if (!p) gs_panic("out of memory mapping a file");
        a->regions = p;
        a->capregions = cap;
    }
    /* A copy cannot be truncated, but a write to it faults as to a mapping. */
    if (r.mem) r.fault = gs_shm_add_fault(r.base, (size_t)r.len, r.path);
    a->regions[++a->nregions] = r;
    *m = (gs_res)(a->serial << GS_RES_REGION_BITS | (uint64_t)a->nregions);
    gs_shm_mapped++;
    gs_shm_unlock();
    return 1;
}

/* The region m names, which att's cache then holds, and its path; or an
   abort, where m names none of att's arena's. `op` is what asks. */
static const char *gs_shm_lookup(gs_att *att, gs_res m, const char *op, const char *file,
                                 int line) {
    struct gs_arena *a = att->arena;
    if (!m) gs_failf(file, line, "%s of the zero handle, which names no mapping", op);
    if (m >> GS_RES_REGION_BITS != a->serial && !gs_shm_live(m >> GS_RES_REGION_BITS))
        gs_failf(file, line, "%s of a mapping of a released shared arena: it was released when "
                 "its last attachment ended", op);
    if (m >> GS_RES_REGION_BITS != a->serial)
        gs_failf(file, line, "%s of a mapping of another shared arena than the attachment's",
                 op);
    int64_t i = (int64_t)(m & (((uint64_t)1 << GS_RES_REGION_BITS) - 1));
    gs_shm_lock();
    if (i < 1 || i > a->nregions) {
        gs_shm_unlock();
        gs_panic("a handle names a region past its shared arena's count");
    }
    gs_shm_region *r = &a->regions[i];
    if (r->elemsize) {
        gs_shm_unlock();
        gs_panic("a mapping's handle names a region of another kind");
    }
    att->res = m;
    att->base = r->base;
    att->len = r->len;
    const char *path = r->path;
    gs_shm_unlock();
    return path;
}

GS_API int64_t gs_shm_size(gs_att *att, gs_res m, const char *file, int line) {
    if (m != att->res || !m) gs_shm_lookup(att, m, "size", file, line);
    return att->len;
}

GS_API const uint8_t *gs_shm_view_slow(gs_att *att, gs_res m, int64_t off, int64_t count,
                                       int64_t size, int64_t align, const char *type,
                                       const char *file, int line) {
    char op[256];
    snprintf(op, sizeof op, "view<%s>", type);
    const char *path = gs_shm_lookup(att, m, op, file, line);
    int64_t len = att->len;
    if (off < 0 || count < 0 || off > len || (uint64_t)count > (uint64_t)(len - off) / (uint64_t)size)
        gs_failf(file, line, "%s of %s out of bounds: count %lld at byte offset %lld, in a "
                 "file of %lld bytes", op, path, (long long)count, (long long)off,
                 (long long)len);
    if (off & (align - 1))
        gs_failf(file, line, "%s of %s misaligned: byte offset %lld is not a multiple of %lld, "
                 "the size of %s's widest scalar", op, path, (long long)off, (long long)align,
                 type);
    return att->base + off;
}

/* With the dynamic stacks, once one was declared: those declared and
   ended, the arrays frozen and released with their arenas, and the slots
   opened fresh, taken again from the free list, and free now. */
GS_API void gs_shm_stats(void) {
    gs_shm_lock();
    fprintf(stderr, "goose shared stats: %lld arenas made, %lld released, %lld live; %lld files "
            "mapped, %lld unmapped\n", (long long)gs_shm_made, (long long)gs_shm_released,
            (long long)gs_narenas, (long long)gs_shm_mapped, (long long)gs_shm_unmapped);
    if (gs_dynbase) {
        int64_t nfree = 0;
        for (int64_t i = gs_dynfree; i >= 0; i = gs_dynslots[i].next) nfree++;
        fprintf(stderr, "goose shared stats: %lld dynamic stacks declared, %lld ended; %lld "
                "arrays frozen, %lld released; %lld slots opened, %lld reused, %lld free\n",
                (long long)gs_dyn_opened, (long long)gs_dyn_closed, (long long)gs_dyn_frozen,
                (long long)gs_dyn_thawed, (long long)gs_dyn_fresh, (long long)gs_dyn_reused,
                (long long)nfree);
    }
    gs_shm_unlock();
}
