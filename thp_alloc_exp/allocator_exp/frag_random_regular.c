#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define SMALL_PAGE_SIZE (4 << 10)

typedef struct arena_state {
    char *base;
    int total_pages;
    int mapped_count;
    int *pages;
    int *pos;
} arena_state;

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int signo)
{
    (void)signo;
    g_stop = 1;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s max_load target_load cycles\n"
            "example: %s 9G 5G 10\n"
            "\n"
            "Behavior:\n"
            "  - mmap only 4KB pages (MADV_NOHUGEPAGE) until max_load\n"
            "  - munmap random 4KB pages down to target_load\n"
            "  - repeat for cycles\n",
            prog, prog);
    exit(1);
}

static long long parse_size(const char *str)
{
    char *end = NULL;
    long long size = strtoull(str, &end, 0);

    if (end == str) {
        return -1;
    }

    switch (*end) {
    case 'g':
    case 'G':
        size *= 1024;
        /* fallthrough */
    case 'm':
    case 'M':
        size *= 1024;
        /* fallthrough */
    case '\0':
    case 'k':
    case 'K':
        size *= 1024;
        break;
    case 'p':
    case 'P':
        size *= 4;
        break;
    default:
        return -1;
    }

    return size;
}

static void swap_page_ids(arena_state *st, int i, int j)
{
    int pi = st->pages[i];
    int pj = st->pages[j];

    st->pages[i] = pj;
    st->pages[j] = pi;
    st->pos[pi] = j;
    st->pos[pj] = i;
}

static void mark_mapped(arena_state *st, int pid)
{
    int idx = st->pos[pid];

    if (idx < st->mapped_count) {
        return;
    }

    swap_page_ids(st, idx, st->mapped_count);
    st->mapped_count++;
}

static void mark_unmapped(arena_state *st, int pid)
{
    int idx = st->pos[pid];

    if (idx >= st->mapped_count) {
        return;
    }

    st->mapped_count--;
    swap_page_ids(st, idx, st->mapped_count);
}

static int map_4k_page(arena_state *st, int pid)
{
    char *addr = st->base + ((size_t)pid * SMALL_PAGE_SIZE);
    void *res = mmap(addr, SMALL_PAGE_SIZE,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                     -1, 0);
    if (res == MAP_FAILED) {
        return -1;
    }

    (void)madvise(addr, SMALL_PAGE_SIZE, MADV_NOHUGEPAGE);

    *(volatile char *)addr = 1;
    mark_mapped(st, pid);
    return 0;
}

static int unmap_4k_page(arena_state *st, int pid)
{
    char *addr = st->base + ((size_t)pid * SMALL_PAGE_SIZE);
    if (munmap(addr, SMALL_PAGE_SIZE) != 0) {
        return -1;
    }

    mark_unmapped(st, pid);
    return 0;
}

static int arena_init(arena_state *st, long long total_pages)
{
    memset(st, 0, sizeof(*st));

    if (total_pages <= 0 || total_pages > INT32_MAX) {
        return -1;
    }

    st->total_pages = (int)total_pages;

    size_t bytes = (size_t)st->total_pages * SMALL_PAGE_SIZE;
    st->base = mmap(NULL, bytes, PROT_NONE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
                    -1, 0);
    if (st->base == MAP_FAILED) {
        st->base = NULL;
        return -1;
    }

    st->pages = malloc((size_t)st->total_pages * sizeof(st->pages[0]));
    st->pos = malloc((size_t)st->total_pages * sizeof(st->pos[0]));
    if (!st->pages || !st->pos) {
        return -1;
    }

    for (int i = 0; i < st->total_pages; i++) {
        st->pages[i] = i;
        st->pos[i] = i;
    }

    return 0;
}

static void arena_destroy(arena_state *st)
{
    if (st->base) {
        size_t bytes = (size_t)st->total_pages * SMALL_PAGE_SIZE;
        munmap(st->base, bytes);
    }

    free(st->pages);
    free(st->pos);
}

int main(int argc, char **argv)
{
    long long max_bytes, target_bytes;
    long long max_pages_ll, target_pages_ll;
    int cycles;
    arena_state st;

    if (argc < 4) {
        usage(argv[0]);
    }

    max_bytes = parse_size(argv[1]);
    target_bytes = parse_size(argv[2]);
    cycles = atoi(argv[3]);

    if (max_bytes <= 0 || target_bytes <= 0 || cycles < 1) {
        usage(argv[0]);
    }

    max_pages_ll = max_bytes / SMALL_PAGE_SIZE;
    target_pages_ll = target_bytes / SMALL_PAGE_SIZE;

    if (target_pages_ll <= 0 || target_pages_ll > max_pages_ll) {
        fprintf(stderr, "invalid bounds: target must be >0 and <= max_load\n");
        return 1;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    srand((unsigned int)time(NULL));

    if (arena_init(&st, max_pages_ll) != 0) {
        fprintf(stderr, "arena_init failed: %s\n", strerror(errno));
        arena_destroy(&st);
        return 1;
    }

    printf("frag_random_regular start: pid=%d max_pages=%lld target_pages=%lld cycles=%d\n",
           getpid(), max_pages_ll, target_pages_ll, cycles);
    fflush(stdout);

    for (int cycle = 1; cycle <= cycles && !g_stop; cycle++) {
        int fill_fail_streak = 0;
        while (st.mapped_count < st.total_pages && !g_stop) {
            int free_count = st.total_pages - st.mapped_count;
            int idx = st.mapped_count + (rand() % free_count);
            int pid = st.pages[idx];

            if (map_4k_page(&st, pid) != 0) {
                fill_fail_streak++;
                if (fill_fail_streak > 100000) {
                    fprintf(stderr, "cycle=%d fill: too many mmap failures, stopping fill\n", cycle);
                    break;
                }
                continue;
            }

            fill_fail_streak = 0;
        }

        int drain_fail_streak = 0;
        while (st.mapped_count > target_pages_ll && !g_stop) {
            int idx = rand() % st.mapped_count;
            int pid = st.pages[idx];

            if (unmap_4k_page(&st, pid) != 0) {
                drain_fail_streak++;
                if (drain_fail_streak > 100000) {
                    fprintf(stderr, "cycle=%d drain: too many munmap failures, stopping drain\n", cycle);
                    break;
                }
                continue;
            }

            drain_fail_streak = 0;
        }

        printf("CYCLE_DONE cycle=%d mapped_pages=%d mapped_kb=%lld\n",
               cycle, st.mapped_count, (long long)st.mapped_count * 4);
        fflush(stdout);
    }

    printf("DONE allocated_pages=%d allocated_kb=%lld\n",
           st.mapped_count, (long long)st.mapped_count * 4);
    fflush(stdout);

    arena_destroy(&st);
    return 0;
}
