/* A file truncated under its mapping: which signal a read past the new end
   raises, with which si_code and address, and whether a handler can tell the
   mapping and the offset (docs/design/shared_memory.md; results in README.md).

       sigbus DIRECTORY

   writes DIRECTORY/sigbus.bin, maps it, truncates it through a second
   descriptor as another process would, and reads inside and past the new
   size. Linux and macOS. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define SIZE (1 << 20)

static const uint8_t *base;

static void handler(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    char msg[200];
    uintptr_t at = (uintptr_t)si->si_addr, b = (uintptr_t)base;
    int n = snprintf(msg, sizeof msg, "%s, si_code %d (BUS_ADRERR is %d), %s the mapping, at byte %lu\n",
                     sig == SIGBUS ? "SIGBUS" : "SIGSEGV", si->si_code, BUS_ADRERR,
                     at - b < SIZE ? "inside" : "outside", (unsigned long)(at - b));
    ssize_t w = write(2, msg, (size_t)n);
    (void)w;
    _exit(1);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: sigbus DIRECTORY\n");
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/sigbus.bin", argv[1]);
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    char *zeros = calloc(1, SIZE);
    if (fd < 0 || write(fd, zeros, SIZE) != SIZE) {
        perror(path);
        return 1;
    }
    base = mmap(NULL, SIZE, PROT_READ, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    printf("a read before truncation: %d\n", base[SIZE - 1]);
    int other = open(path, O_RDWR);
    if (other < 0 || ftruncate(other, 4096)) {
        perror("ftruncate");
        return 1;
    }
    printf("a read inside the new size: %d\n", base[100]);
    fflush(stdout);
    volatile uint8_t past = base[8192];
    printf("not reached: %d\n", past);
    return 0;
}
