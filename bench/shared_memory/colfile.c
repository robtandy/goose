/* The column file mapbench reads (docs/design/shared_memory.md, 11.1).

       colfile write FILE N    writes N little-endian i64s, 0 to N - 1
       colfile drop FILE       drops the file's pages from the page cache
                               (POSIX_FADV_DONTNEED; needs no privileges)

   Linux. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "write")) {
        FILE *f = fopen(argv[2], "wb");
        int64_t n = atoll(argv[3]), per = (1 << 20) / 8;
        int64_t *buf = malloc(1 << 20);
        if (!f || !buf || n < 0) return 1;
        for (int64_t i = 0; i < n; i += per) {
            int64_t k = n - i < per ? n - i : per;
            for (int64_t j = 0; j < k; j++) buf[j] = i + j;
            if (fwrite(buf, 8, (size_t)k, f) != (size_t)k) return 1;
        }
        return fclose(f) ? 1 : 0;
    }
    if (argc == 3 && !strcmp(argv[1], "drop")) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) return 1;
        return posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED) ? 1 : 0;
    }
    fprintf(stderr, "usage: colfile write FILE N | colfile drop FILE\n");
    return 2;
}
