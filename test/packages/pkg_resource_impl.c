/* The C side of pkg_resource.goose, compiled from its sidecar: a binding of
   two kinds of resource<U> (spec 3.12), native byte buffers and a stand-in
   for a GPU's buffers, which owns its objects and names each by a handle it
   makes, as docs/design/owning_dynamic_data.md's option C has it. A handle
   crosses as the uint64_t it is, goose.h's gs_res. Its bits are this file's
   business:

     bits 63..56   the kind, KIND_BYTES or KIND_GPU
     bits 55..32   the slot's generation, which moves on at each release
     bits 31..0    the slot's number plus one

   so no handle is 0, which names nothing, and a released object's handle is
   stale rather than naming whatever its slot holds next. Every handle Goose
   hands back is checked against the table before it is used. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "goose.h"

enum { KIND_BYTES = 1, KIND_GPU = 2, SLOTS = 4 };

typedef struct {
    uint64_t kind;
    uint64_t gen;
    int live;
    int64_t size;      /* bytes, or floats for KIND_GPU */
    void *mem;
} Obj;

static Obj objs[SLOTS];

/* A const T[:] parameter: its data pointer and length (spec 7.10). */
typedef struct { const uint8_t *data; int64_t len; } Bytes;
typedef struct { const float *data; int64_t len; } Floats;
typedef struct { const gs_res *data; int64_t len; } Handles;

/* Named { tag: i64, buf: resource<ByteBuffer> }, by value: its packed C
   form, 16 bytes with each field where C places it, which every C compiler
   passes in two registers on x86-64 and arm64. */
#pragma pack(push, 1)
typedef struct { int64_t tag; gs_res buf; } Named;
#pragma pack(pop)

static gs_res make(uint64_t kind, int64_t size, size_t elem) {
    if (size < 0) return 0;
    for (int i = 0; i < SLOTS; i++) {
        Obj *o = &objs[i];
        if (o->live) continue;
        o->mem = calloc((size_t)size + 1, elem);
        if (!o->mem) return 0;
        o->kind = kind;
        o->live = 1;
        o->size = size;
        return kind << 56 | (o->gen & 0xFFFFFF) << 32 | (uint64_t)(i + 1);
    }
    return 0;
}

/* The object a handle names, if it is a live one of this kind. */
static Obj *find(gs_res h, uint64_t kind) {
    uint64_t slot = h & 0xFFFFFFFF;
    if (slot == 0 || slot > SLOTS || h >> 56 != kind) return NULL;
    Obj *o = &objs[slot - 1];
    if (!o->live || (o->gen & 0xFFFFFF) != (h >> 32 & 0xFFFFFF)) return NULL;
    return o;
}

static uint8_t release(gs_res h, uint64_t kind) {
    Obj *o = find(h, kind);
    if (!o) return 0;
    free(o->mem);
    o->mem = NULL;
    o->live = 0;
    o->gen++;
    return 1;
}

gs_res bytes_new(int64_t size) { return make(KIND_BYTES, size, 1); }

int64_t bytes_size(gs_res b) {
    Obj *o = find(b, KIND_BYTES);
    return o ? o->size : -1;
}

uint8_t bytes_write(gs_res b, int64_t at, Bytes data) {
    Obj *o = find(b, KIND_BYTES);
    if (!o || at < 0 || data.len > o->size - at) return 0;
    memcpy((uint8_t *)o->mem + at, data.data, (size_t)data.len);
    return 1;
}

uint8_t bytes_read(gs_res b, int64_t at, int64_t n, gs_rref out) {
    Obj *o = find(b, KIND_BYTES);
    if (!o || at < 0 || n < 0 || n > o->size - at) return 0;
    gs_bld_append(out, (uint8_t *)o->mem + at, n);
    return 1;
}

uint8_t bytes_release(gs_res b) { return release(b, KIND_BYTES); }

/* A handle handed back through a resource<ByteBuffer>& parameter. */
uint8_t bytes_new_into(int64_t size, gs_res *out) {
    *out = bytes_new(size);
    return *out != 0;
}

/* The sizes of the buffers a slice of handles names; -1 if one is none. */
int64_t bytes_total(Handles bs) {
    int64_t total = 0;
    for (int64_t i = 0; i < bs.len; i++) {
        Obj *o = find(bs.data[i], KIND_BYTES);
        if (!o) return -1;
        total += o->size;
    }
    return total;
}

int64_t named_size(Named n) { return n.tag * 1000 + bytes_size(n.buf); }

/* What C sees of a handle: 0 for the zero handle, and the slot it made it
   for otherwise. */
uint8_t bytes_is_zero(gs_res b) { return b == 0; }
int64_t bytes_slot(gs_res b) { return find(b, KIND_BYTES) ? (int64_t)(b & 0xFFFFFFFF) - 1 : -1; }

gs_res gpu_create(int64_t n) { return make(KIND_GPU, n, sizeof(float)); }

uint8_t gpu_upload(gs_res g, Floats data) {
    Obj *o = find(g, KIND_GPU);
    if (!o || data.len > o->size) return 0;
    memcpy(o->mem, data.data, (size_t)data.len * sizeof(float));
    return 1;
}

/* Draws what was uploaded: here, its sum. -1 for a handle that names no live
   buffer of this kind. */
double gpu_draw(gs_res g) {
    Obj *o = find(g, KIND_GPU);
    if (!o) return -1;
    double sum = 0;
    for (int64_t i = 0; i < o->size; i++) sum += ((const float *)o->mem)[i];
    return sum;
}

uint8_t gpu_release(gs_res g) { return release(g, KIND_GPU); }
