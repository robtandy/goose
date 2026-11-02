/* The C side of colsum.goose, from its sidecar (colsum.build): a file opened
   once and read at an offset into a buffer the caller reuses, as pread does,
   which any thread may call at once. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

typedef struct { const uint8_t *data; int64_t len; } Bytes;
typedef struct { int64_t *data; int64_t len; } I64s;

/* The file's descriptor (a HANDLE on Windows), or -1. */
int64_t col_open(Bytes path) {
    char *p = (char *)malloc((size_t)path.len + 1);
    if (!p) return -1;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
#ifdef _WIN32
    HANDLE h = CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    free(p);
    return h == INVALID_HANDLE_VALUE ? -1 : (int64_t)(intptr_t)h;
#else
    int fd = open(p, O_RDONLY);
    free(p);
    return fd;
#endif
}

/* buf.len i64s from byte `off`: the bytes read, short only at the end. */
int64_t col_pread(int64_t fd, int64_t off, I64s buf) {
    uint8_t *dst = (uint8_t *)buf.data;
    int64_t want = buf.len * 8, done = 0;
    while (done < want) {
#ifdef _WIN32
        OVERLAPPED o;
        memset(&o, 0, sizeof o);
        o.Offset = (DWORD)(off + done);
        o.OffsetHigh = (DWORD)((uint64_t)(off + done) >> 32);
        DWORD got = 0;
        DWORD n = want - done > (1 << 30) ? 1u << 30 : (DWORD)(want - done);
        if (!ReadFile((HANDLE)(intptr_t)fd, dst + done, n, &got, &o) || got == 0) break;
#else
        ssize_t got = pread((int)fd, dst + done, (size_t)(want - done), (off_t)(off + done));
        if (got <= 0) break;
#endif
        done += (int64_t)got;
    }
    return done;
}

void col_close(int64_t fd) {
#ifdef _WIN32
    CloseHandle((HANDLE)(intptr_t)fd);
#else
    close((int)fd);
#endif
}
