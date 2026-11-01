/* Summing an i64 column from a file in the page cache: by pread into a
   buffer each thread reuses, by reading the whole file into memory first,
   and through one shared read-only mapping, with and without prefaulting
   (docs/design/shared_memory.md; results in README.md).

   Morsels of 983040 bytes, 122880 i64s each, are handed out by an atomic
   counter, as a morsel queue would hand them out.

       mapbench FILE MODE THREADS [PASSES]

   MODE is pread, readall, mmap, mmap_populate (MAP_POPULATE),
   mmap_popread (MADV_POPULATE_READ per morsel) or mmap_willneed
   (MADV_WILLNEED per morsel). PASSES > 1 scans a mapping again, with its
   page tables populated. Linux; the madvise modes need Linux 5.14. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifndef MADV_POPULATE_READ
#define MADV_POPULATE_READ 22
#endif

#define MORSEL 983040
#define MAX_THREADS 256

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

static const char *mode;
static int fd;
static int64_t fsize, nmorsels;
static const uint8_t *map;
static atomic_long next;
static atomic_llong total;

static int64_t sum_i64(const int64_t *p, int64_t n) {
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) s += p[i];
    return s;
}

static void *worker(void *arg) {
    (void)arg;
    int64_t s = 0;
    int64_t *buf = NULL;
    if (!strcmp(mode, "pread")) buf = aligned_alloc(4096, MORSEL);
    for (;;) {
        long m = atomic_fetch_add(&next, 1);
        if (m >= nmorsels) break;
        int64_t off = m * (int64_t)MORSEL;
        int64_t len = fsize - off < MORSEL ? fsize - off : MORSEL;
        if (buf) {
            for (int64_t done = 0; done < len;) {
                ssize_t r = pread(fd, (char *)buf + done, (size_t)(len - done), off + done);
                if (r <= 0) {
                    perror("pread");
                    exit(1);
                }
                done += r;
            }
            s += sum_i64(buf, len / 8);
        } else {
            if (!strcmp(mode, "mmap_popread")) madvise((void *)(map + off), (size_t)len, MADV_POPULATE_READ);
            if (!strcmp(mode, "mmap_willneed")) madvise((void *)(map + off), (size_t)len, MADV_WILLNEED);
            s += sum_i64((const int64_t *)(map + off), len / 8);
        }
    }
    free(buf);
    atomic_fetch_add(&total, s);
    return NULL;
}

static double scan(int threads) {
    pthread_t t[MAX_THREADS];
    atomic_store(&next, 0);
    atomic_store(&total, 0);
    int64_t t0 = now_ns();
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, worker, NULL);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    return (now_ns() - t0) / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: mapbench FILE MODE THREADS [PASSES]\n");
        return 2;
    }
    mode = argv[2];
    int threads = atoi(argv[3]), passes = argc > 4 ? atoi(argv[4]) : 1;
    if (threads < 1 || threads > MAX_THREADS || passes < 1) return 2;
    fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) {
        perror(argv[1]);
        return 1;
    }
    fsize = st.st_size;
    nmorsels = (fsize + MORSEL - 1) / MORSEL;
    double setup = 0;
    if (!strcmp(mode, "readall")) {
        int64_t t0 = now_ns();
        uint8_t *all = malloc((size_t)fsize);
        for (int64_t done = 0; done < fsize;) {
            ssize_t r = pread(fd, all + done, (size_t)(fsize - done), done);
            if (r <= 0) return 1;
            done += r;
        }
        setup = (now_ns() - t0) / 1e9;
        map = all;
    } else if (!strncmp(mode, "mmap", 4)) {
        int64_t t0 = now_ns();
        int flags = MAP_SHARED | (!strcmp(mode, "mmap_populate") ? MAP_POPULATE : 0);
        map = mmap(NULL, (size_t)fsize, PROT_READ, flags, fd, 0);
        if (map == MAP_FAILED) {
            perror("mmap");
            return 1;
        }
        setup = (now_ns() - t0) / 1e9;
    } else if (strcmp(mode, "pread")) {
        fprintf(stderr, "mapbench: unknown mode %s\n", mode);
        return 2;
    }
    for (int p = 0; p < passes; p++) {
        double secs = scan(threads), with = secs + (p ? 0 : setup);
        printf("%-14s threads=%3d pass=%d setup=%.3fs scan=%.3fs: %.2f GB/s, %.2f GB/s with the setup (sum %lld)\n",
               argv[2], threads, p, p ? 0.0 : setup, secs, fsize / secs / 1e9, fsize / with / 1e9,
               (long long)atomic_load(&total));
    }
    if (!strncmp(mode, "mmap", 4)) {
        int64_t t0 = now_ns();
        munmap((void *)map, (size_t)fsize);
        printf("%-14s munmap %.1f ms\n", argv[2], (now_ns() - t0) / 1e6);
    }
    return 0;
}
