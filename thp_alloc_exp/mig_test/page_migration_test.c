#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <numa.h>
#include <numaif.h>
#include <sched.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include <ctype.h>

#ifndef PR_SET_NMPDBG
#define PR_SET_NMPDBG 0x5F30
#define PR_GET_NMPDBG 0x5F31
#endif

static void die(const char *msg) { perror(msg); exit(1); }

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void pin_to_node_cpus(int node) {
    struct bitmask *cpus = numa_allocate_cpumask();
    if (!cpus) die("numa_allocate_cpumask");
    if (numa_node_to_cpus(node, cpus) != 0) die("numa_node_to_cpus");
    if (numa_sched_setaffinity(0, cpus) != 0) die("numa_sched_setaffinity");
    numa_free_cpumask(cpus);
}

static void sample_numa_maps(void *base) {
    FILE *f = fopen("/proc/self/numa_maps", "r");
    if (!f) { perror("open /proc/self/numa_maps"); return; }
    char *line = NULL; size_t cap = 0;
    unsigned long long target = (unsigned long long)(uintptr_t)base;
    while (getline(&line, &cap, f) > 0) {
        unsigned long long addr = 0;
        if (sscanf(line, "%llx", &addr) == 1 && addr == target) {
            int node, cnt; char *p = line;
            printf("[numa_maps] nodes:");
            while ((p = strstr(p, "N")) != NULL) {
                if (sscanf(p, "N%d=%d", &node, &cnt) == 2) printf(" N%d=%d", node, cnt);
                p++;
            }
            printf("\n");
            break;
        }
    }
    free(line);
    fclose(f);
}

static void verify_mincore(void *base, size_t len, long page, const char *tag) {
    size_t pages = (len + page - 1) / page;
    unsigned char *vec = (unsigned char *)malloc(pages);
    if (!vec) { perror("malloc vec"); return; }
    if (mincore(base, len, vec) != 0) {
        perror("mincore");
        free(vec);
        return;
    }
    size_t resident = 0;
    for (size_t i = 0; i < pages; ++i) resident += (vec[i] & 1) ? 1 : 0;
    printf("[mincore] %s: %zu/%zu pages resident (%.2f%%)\n",
           tag, resident, pages, pages ? (100.0 * resident / pages) : 0.0);
    free(vec);
}

static void init_region_int1_volatile(char *base, size_t n_pages, long page) {
    for (size_t i = 0; i < n_pages; ++i) {
        volatile int *pi = (volatile int *)(base + i * page);
        size_t nints = (size_t)page / sizeof(int);
        for (size_t j = 0; j < nints; ++j) {
            pi[j] = 1;
        }
        size_t rem = (size_t)page - nints * sizeof(int);
        volatile unsigned char *pb = (volatile unsigned char *)((char*)pi + nints * sizeof(int));
        for (size_t r = 0; r < rem; ++r) pb[r] = 1;
    }
}

static void sweep_pages(char *base, size_t n_pages, long page, size_t inner_step) {
    for (size_t i = 0; i < n_pages; ++i) {
        volatile unsigned char *pg = (volatile unsigned char *)(base + i * page);
        for (size_t off = 0; off < (size_t)page; off += inner_step) {
            pg[off]++;
        }
        if (((size_t)page - 1) % inner_step != 0) {
            pg[(size_t)page - 1]++;
        }
    }
}

static void usage(const char *argv0) {
    fprintf(stderr,
        "Usage: %s [--size-gb N (default 50)] [--src-node 1] [--dst-node 0]\n"
        "          [--loop-pages P | --loop-gb G] [--inner-step BYTES (default 64)] [--verify]\n"
        "\n"
        "Flow (AutoNUMA-friendly):\n"
        "  1) Map N GiB anonymous (THP disabled).\n"
        "  2) Pin to src-node; VOLATILE-fill the first P pages / G GiB to int(1) (forces real allocation & use).\n"
        "  3) Pin to dst-node; do 10 full sweeps (no skipping) with given inner-step.\n"
        "Notes: No move_pages/mbind/mempolicy; optional mincore() residency checks.\n",
        argv0);
    exit(2);
}

int main(int argc, char **argv) {
    if (numa_available() < 0) die("libnuma not available or no NUMA");

    const long page = sysconf(_SC_PAGESIZE);
    int src_node = 1;
    int dst_node = 0;
    size_t size_gb = 50;

    size_t loop_pages = 0;
    size_t loop_gb = 0;
    size_t inner_step = 64;
    bool verify = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--size-gb") && i+1 < argc) size_gb = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--src-node") && i+1 < argc) src_node = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dst-node") && i+1 < argc) dst_node = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--loop-pages") && i+1 < argc) loop_pages = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--loop-gb") && i+1 < argc) loop_gb = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--inner-step") && i+1 < argc) inner_step = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--verify")) verify = true;
        else usage(argv[0]);
    }

    if (inner_step == 0 || inner_step > (size_t)page) {
        fprintf(stderr, "inner-step must be in [1, %ld]\n", page);
        return 2;
    }

    int maxnode = numa_max_node();
    if (src_node > maxnode || dst_node > maxnode) {
        fprintf(stderr, "This machine has nodes 0..%d; you asked for %d/%d\n",
                maxnode, src_node, dst_node);
        return 1;
    }
    // if (src_node == dst_node) {
    //     fprintf(stderr, "src-node and dst-node must differ.\n");
    //     return 1;
    // }

    if (prctl(PR_SET_NMPDBG, 1, 0, 0, 0) != 0) {
        perror("prctl(PR_SET_NMPDBG) (continuing)");
    } else {
        int flag = prctl(PR_GET_NMPDBG, 0, 0, 0, 0);
        printf("nmpdbg flag (mm) = %d\n", flag);
    }

    size_t bytes = size_gb * (size_t)1024 * 1024 * 1024;
    printf("Mapping %zu GiB (%zu bytes)\n", size_gb, bytes);

    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) die("mmap");

    // (void)madvise(p, bytes, MADV_NOHUGEPAGE);

    size_t total_pages = bytes / (size_t)page;
    size_t active_pages = total_pages;
    if (loop_gb > 0) {
        __uint128_t req_bytes = (__uint128_t)loop_gb * 1024ULL * 1024ULL * 1024ULL;
        size_t req_pages = (size_t)(req_bytes / (unsigned)page);
        if (req_pages < active_pages) active_pages = req_pages;
    }
    if (loop_pages > 0 && loop_pages < active_pages) {
        active_pages = loop_pages;
    }
    size_t active_bytes = active_pages * (size_t)page;
    // if (loop_gb > 0) {
    //     __uint128_t req_bytes = (__uint128_t)loop_gb * 1024ULL * 1024ULL * 1024ULL;
    //     size_t req_pages = (size_t)(req_bytes / (unsigned)page);
    //     if (req_pages < active_pages) active_pages = req_pages;
    // }
    // if (loop_pages > 0 && loop_pages < active_pages) {
    //     active_pages = loop_pages;
    // }
    // size_t active_bytes = active_pages * (size_t)page;

    printf("Active working set: %zu pages (%.2f GiB), inner-step=%zu bytes\n",
           active_pages, (double)active_bytes / (1024.0*1024.0*1024.0), inner_step);

    printf("[INIT] Pinning to src_node=%d and filling to int(1)…\n", src_node);
    pin_to_node_cpus(src_node);

    double t0 = now_sec();
    init_region_int1_volatile((char *)p, total_pages, page);
    double t1 = now_sec();

    double gb = (double)active_bytes / (1024.0*1024.0*1024.0);
    double dt = t1 - t0;
    printf("[INIT] Wrote %.2f GiB in %.3f s  (%.2f GiB/s)\n", gb, dt, dt > 0 ? gb/dt : 0.0);
    sample_numa_maps(p);
    if (verify) verify_mincore(p, active_bytes, page, "after INIT");

    printf("[RUN ] Pinning to dst_node=%d and starting 10 full sweeps…\n", dst_node);
    pin_to_node_cpus(dst_node);

    for (int pass = 1; pass <= 20; ++pass) {
        double ps = now_sec();
        sweep_pages((char *)p, active_pages, page, inner_step);
        double pe = now_sec();
        double gbs = (double)active_bytes / (1024.0*1024.0*1024.0);
        double dps = pe - ps;
        printf("  Sweep %d/10: %.2f GiB in %.3f s  (%.2f GiB/s)\n",
               pass, gbs, dps, dps > 0 ? gbs/dps : 0.0);

        if (pass == 5 || pass == 10 || pass == 15 || pass == 20) {
            sample_numa_maps(p);
            if (verify) verify_mincore(p, active_bytes, page, pass == 5 ? "after SWEEP5" : "after SWEEP10");
        }
    }

    printf("Sleeping 10s to allow background migrations to settle…\n");
    sleep(10);

    munmap(p, bytes);
    return 0;
}
