/* The C side of resource_threads.goose, compiled from its sidecar: tokens,
   whose handles carry a number and a check of it,

     bit 63        1, so that no token's handle is 0
     bits 62..8    the number
     bits 7..0     a check of the number

   and which give the number back only for a handle made here, intact. It
   keeps no state, so any thread may call it. */
#include <stdint.h>

static uint64_t check(uint64_t n) { return (n * 0x9E3779B97F4A7C15ull) >> 56; }

uint64_t token_make(int64_t n) {
    if (n < 0 || n >= (int64_t)1 << 54) return 0;
    return (uint64_t)1 << 63 | (uint64_t)n << 8 | check((uint64_t)n);
}

/* -1 for a handle this file did not make: the zero handle among them. */
int64_t token_number(uint64_t t) {
    if (!(t >> 63)) return -1;
    uint64_t n = (t & ~((uint64_t)1 << 63)) >> 8;
    return (t & 0xFF) == check(n) ? (int64_t)n : -1;
}
