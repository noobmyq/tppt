#include <ctype.h>
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

#define HUGE_PAGE_SIZE (2 << 20)
#define SMALL_PAGE_SIZE (4 << 10)
#define PAGES_PER_HUGE (HUGE_PAGE_SIZE / SMALL_PAGE_SIZE)
#define MAX_MARKS 256

typedef struct arena_state {
    char *base;
    int total_pages;
    int mapped_count;

    int num_slots;
    int *slot_pages;
    int *slot_mapped;

    int full_slot_count;
    int *full_slots;

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
            "usage: %s upper lower pin_density cycles [fill_pause_hpages] [drain_pause_hpages] [pause_marks_csv] [alloc_mode]\n"
            "example: %s 9G 5G 128 5 0 0 1G,2G,3G mixed\n"
            "\n"
            "Behavior:\n"
            "  - fill to upper (always try 2MB first on empty 2MB slots, then 4KB fallback)\n"
            "  - random 4KB unmap down to lower\n"
            "  - repeat for cycles\n"
            "  - alloc_mode: mixed (default) | regular (4KB-only + MADV_NOHUGEPAGE)\n",
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

static int cmp_ll(const void *a, const void *b)
{
    long long x = *(const long long *)a;
    long long y = *(const long long *)b;
    if (x < y)
        return -1;
    if (x > y)
        return 1;
    return 0;
}

static int parse_pause_marks_csv(const char *csv,
                                 long long *marks_pages,
                                 int marks_cap,
                                 long long total_pages)
{
    int count = 0;

    if (!csv || !*csv) {
        return 0;
    }

    char *buf = strdup(csv);
    if (!buf) {
        return 0;
    }

    char *saveptr = NULL;
    char *tok = strtok_r(buf, ",", &saveptr);
    while (tok && count < marks_cap) {
        while (*tok && isspace((unsigned char)*tok)) {
            tok++;
        }

        size_t len = strlen(tok);
        while (len > 0 && isspace((unsigned char)tok[len - 1])) {
            tok[--len] = '\0';
        }

        if (*tok) {
            long long bytes = parse_size(tok);
            long long pages = bytes / SMALL_PAGE_SIZE;
            if (bytes > 0 && pages > 0 && pages <= total_pages) {
                marks_pages[count++] = pages;
            }
        }

        tok = strtok_r(NULL, ",", &saveptr);
    }

    free(buf);

    if (count <= 1) {
        return count;
    }

    qsort(marks_pages, count, sizeof(marks_pages[0]), cmp_ll);

    int unique = 1;
    for (int i = 1; i < count; i++) {
        if (marks_pages[i] != marks_pages[unique - 1]) {
            marks_pages[unique++] = marks_pages[i];
        }
    }

    return unique;
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

static int mark_mapped(arena_state *st, int pid)
{
    int idx = st->pos[pid];
    if (idx < st->mapped_count) {
        return 0;
    }

    swap_page_ids(st, idx, st->mapped_count);
    st->mapped_count++;
    st->slot_mapped[pid / PAGES_PER_HUGE]++;
    return 0;
}

static int mark_unmapped(arena_state *st, int pid)
{
    int idx = st->pos[pid];
    if (idx >= st->mapped_count) {
        return 0;
    }

    st->mapped_count--;
    swap_page_ids(st, idx, st->mapped_count);
    st->slot_mapped[pid / PAGES_PER_HUGE]--;
    return 0;
}

static int map_4k_page(arena_state *st, int pid, bool no_hugepage)
{
    char *addr = st->base + ((size_t)pid * SMALL_PAGE_SIZE);
    void *res = mmap(addr, SMALL_PAGE_SIZE,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                     -1, 0);
    if (res == MAP_FAILED) {
        return -1;
    }

    if (no_hugepage) {
        (void)madvise(addr, SMALL_PAGE_SIZE, MADV_NOHUGEPAGE);
    }

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

static int map_2m_slot(arena_state *st, int slot)
{
    if (slot < 0 || slot >= st->num_slots) {
        return -1;
    }

    if (st->slot_pages[slot] != PAGES_PER_HUGE) {
        return 0;
    }

    if (st->slot_mapped[slot] != 0) {
        return 0;
    }

    char *addr = st->base + ((size_t)slot * HUGE_PAGE_SIZE);
    void *res = mmap(addr, HUGE_PAGE_SIZE,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                     -1, 0);
    if (res == MAP_FAILED) {
        return -1;
    }

    (void)madvise(addr, HUGE_PAGE_SIZE, MADV_HUGEPAGE);

    for (int off = 0; off < PAGES_PER_HUGE; off++) {
        char *p = addr + ((size_t)off * SMALL_PAGE_SIZE);
        *(volatile char *)p = 1;
    }

    int start = slot * PAGES_PER_HUGE;
    for (int i = 0; i < PAGES_PER_HUGE; i++) {
        mark_mapped(st, start + i);
    }

    return 1;
}

static void shuffle_ints(int *arr, int n)
{
    if (n <= 1) {
        return;
    }
    for (int i = n - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        int t = arr[i];
        arr[i] = arr[j];
        arr[j] = t;
    }
}

static int checkpoint_pause(int pause_idx,
                            int cycle,
                            const char *phase,
                            long long allocated_pages,
                            long long cap_pages,
                            long long target_pages)
{
    if (g_stop) {
        return -1;
    }

    time_t now = time(NULL);
    printf("CHECKPOINT pause_idx=%d cycle=%d phase=%s allocated_pages=%lld allocated_kb=%lld cap_pages=%lld target_pages=%lld\n",
           pause_idx,
           cycle,
           phase,
           allocated_pages,
           allocated_pages * 4,
           cap_pages,
           target_pages);
    printf("PAUSE_ENTER ts=%lld pause_idx=%d cycle=%d phase=%s\n",
           (long long)now, pause_idx, cycle, phase);
    fflush(stdout);

    raise(SIGSTOP);

    now = time(NULL);
    printf("PAUSE_RESUME ts=%lld pause_idx=%d cycle=%d phase=%s\n",
           (long long)now, pause_idx, cycle, phase);
    fflush(stdout);

    return g_stop ? -1 : 0;
}

static int maybe_trigger_fill_pauses(int *pause_idx,
                                     int cycle,
                                     long long current_pages,
                                     long long cap_pages,
                                     long long target_pages,
                                     long long *fill_since_pages,
                                     long long fill_step_pages,
                                     const long long *marks_pages,
                                     int mark_count,
                                     int *next_mark_idx)
{
    while (fill_step_pages > 0 && *fill_since_pages >= fill_step_pages) {
        if (checkpoint_pause(++(*pause_idx), cycle, "fill_step", current_pages,
                             cap_pages, target_pages) != 0) {
            return -1;
        }
        *fill_since_pages -= fill_step_pages;
    }

    while (*next_mark_idx < mark_count && current_pages >= marks_pages[*next_mark_idx]) {
        if (checkpoint_pause(++(*pause_idx), cycle, "fill_mark", current_pages,
                             cap_pages, target_pages) != 0) {
            return -1;
        }
        (*next_mark_idx)++;
    }

    return 0;
}

static int maybe_trigger_drain_pauses(int *pause_idx,
                                      int cycle,
                                      long long current_pages,
                                      long long cap_pages,
                                      long long target_pages,
                                      long long *drain_since_pages,
                                      long long drain_step_pages,
                                      const long long *marks_pages,
                                      int *drain_mark_idx)
{
    while (drain_step_pages > 0 && *drain_since_pages >= drain_step_pages) {
        if (checkpoint_pause(++(*pause_idx), cycle, "drain_step", current_pages,
                             cap_pages, target_pages) != 0) {
            return -1;
        }
        *drain_since_pages -= drain_step_pages;
    }

    while (*drain_mark_idx >= 0 && current_pages <= marks_pages[*drain_mark_idx]) {
        if (checkpoint_pause(++(*pause_idx), cycle, "drain_mark", current_pages,
                             cap_pages, target_pages) != 0) {
            return -1;
        }
        (*drain_mark_idx)--;
    }

    return 0;
}

static int arena_init(arena_state *st, long long total_pages)
{
    memset(st, 0, sizeof(*st));

    if (total_pages <= 0 || total_pages > INT32_MAX) {
        return -1;
    }

    st->total_pages = (int)total_pages;
    st->num_slots = (st->total_pages + PAGES_PER_HUGE - 1) / PAGES_PER_HUGE;

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
    st->slot_pages = calloc((size_t)st->num_slots, sizeof(st->slot_pages[0]));
    st->slot_mapped = calloc((size_t)st->num_slots, sizeof(st->slot_mapped[0]));
    st->full_slots = malloc((size_t)st->num_slots * sizeof(st->full_slots[0]));

    if (!st->pages || !st->pos || !st->slot_pages || !st->slot_mapped || !st->full_slots) {
        return -1;
    }

    for (int i = 0; i < st->total_pages; i++) {
        st->pages[i] = i;
        st->pos[i] = i;
    }

    st->full_slot_count = 0;
    for (int s = 0; s < st->num_slots; s++) {
        int start = s * PAGES_PER_HUGE;
        int left = st->total_pages - start;
        st->slot_pages[s] = left >= PAGES_PER_HUGE ? PAGES_PER_HUGE : left;
        if (st->slot_pages[s] == PAGES_PER_HUGE) {
            st->full_slots[st->full_slot_count++] = s;
        }
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
    free(st->slot_pages);
    free(st->slot_mapped);
    free(st->full_slots);
}

int main(int argc, char **argv)
{
    long long upper_bytes, lower_bytes;
    long long upper_pages_ll, lower_pages_ll;
    int pin_density_arg, cycles;
    int fill_pause_hpages = 0;
    int drain_pause_hpages = 0;
    long long fill_step_pages, drain_step_pages;
    const char *pause_marks_csv = "";
    const char *alloc_mode = "mixed";
    bool use_huge_fill = true;
    bool no_hugepage_4k = false;
    long long marks_pages[MAX_MARKS];
    int marks_count;

    arena_state st;
    int pause_idx = 0;

    if (argc < 5) {
        usage(argv[0]);
    }

    upper_bytes = parse_size(argv[1]);
    lower_bytes = parse_size(argv[2]);
    pin_density_arg = atoi(argv[3]);
    cycles = atoi(argv[4]);

    if (argc >= 6) {
        fill_pause_hpages = atoi(argv[5]);
    }
    if (argc >= 7) {
        drain_pause_hpages = atoi(argv[6]);
    }
    if (argc >= 8) {
        pause_marks_csv = argv[7];
    }
    if (argc >= 9) {
        alloc_mode = argv[8];
        if (strcmp(alloc_mode, "mixed") == 0) {
            use_huge_fill = true;
            no_hugepage_4k = false;
        } else if (strcmp(alloc_mode, "regular") == 0 ||
                   strcmp(alloc_mode, "regular_only") == 0 ||
                   strcmp(alloc_mode, "4k") == 0) {
            use_huge_fill = false;
            no_hugepage_4k = true;
        } else {
            fprintf(stderr, "invalid alloc_mode '%s' (expected mixed|regular)\n", alloc_mode);
            return 1;
        }
    }

    if (upper_bytes <= 0 || lower_bytes <= 0 || cycles < 1 ||
        fill_pause_hpages < 0 || drain_pause_hpages < 0) {
        usage(argv[0]);
    }

    upper_pages_ll = upper_bytes / SMALL_PAGE_SIZE;
    lower_pages_ll = lower_bytes / SMALL_PAGE_SIZE;

    if (lower_pages_ll <= 0 || lower_pages_ll > upper_pages_ll) {
        fprintf(stderr, "invalid bounds: lower must be >0 and <= upper\n");
        return 1;
    }

    fill_step_pages = (long long)fill_pause_hpages * PAGES_PER_HUGE;
    drain_step_pages = (long long)drain_pause_hpages * PAGES_PER_HUGE;
    marks_count = parse_pause_marks_csv(pause_marks_csv, marks_pages, MAX_MARKS, upper_pages_ll);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    srand((unsigned int)time(NULL));

    if (arena_init(&st, upper_pages_ll) != 0) {
        fprintf(stderr, "arena_init failed: %s\n", strerror(errno));
        arena_destroy(&st);
        return 1;
    }

    printf("frag_random_pause start: pid=%d upper_pages=%lld lower_pages=%lld cycles=%d pin_arg=%d fill_step_hpages=%d drain_step_hpages=%d marks=%d alloc_mode=%s\n",
           getpid(), upper_pages_ll, lower_pages_ll, cycles, pin_density_arg,
           fill_pause_hpages, drain_pause_hpages, marks_count, alloc_mode);
    if (marks_count > 0) {
        printf("pause_marks_pages:");
        for (int i = 0; i < marks_count; i++) {
            printf(" %lld", marks_pages[i]);
        }
        printf("\n");
    }
    fflush(stdout);

    for (int cycle = 1; cycle <= cycles && !g_stop; cycle++) {
        long long fill_since_pause = 0;
        int fill_next_mark = 0;

        while (fill_next_mark < marks_count && marks_pages[fill_next_mark] <= st.mapped_count) {
            fill_next_mark++;
        }

        if (use_huge_fill) {
            if (st.full_slot_count > 1) {
                shuffle_ints(st.full_slots, st.full_slot_count);
            }

            // 2MB-first fill on empty full slots.
            for (int i = 0; i < st.full_slot_count && !g_stop; i++) {
                if (st.mapped_count + PAGES_PER_HUGE > st.total_pages) {
                    break;
                }

                int slot = st.full_slots[i];
                if (st.slot_mapped[slot] != 0) {
                    continue;
                }

                int rc = map_2m_slot(&st, slot);
                if (rc <= 0) {
                    continue;
                }

                fill_since_pause += PAGES_PER_HUGE;
                if (maybe_trigger_fill_pauses(&pause_idx, cycle,
                                              st.mapped_count,
                                              upper_pages_ll, lower_pages_ll,
                                              &fill_since_pause, fill_step_pages,
                                              marks_pages, marks_count,
                                              &fill_next_mark) != 0) {
                    goto done;
                }
            }
        }

        // 4KB fallback fill to exact upper bound.
        int fill_fail_streak = 0;
        while (st.mapped_count < st.total_pages && !g_stop) {
            int free_count = st.total_pages - st.mapped_count;
            if (free_count <= 0) {
                break;
            }

            int idx = st.mapped_count + (rand() % free_count);
            int pid = st.pages[idx];

            if (map_4k_page(&st, pid, no_hugepage_4k) != 0) {
                fill_fail_streak++;
                if (fill_fail_streak > 100000) {
                    fprintf(stderr, "fill fallback: too many mmap failures, stopping fill\n");
                    break;
                }
                continue;
            }

            fill_fail_streak = 0;
            fill_since_pause++;
            if (maybe_trigger_fill_pauses(&pause_idx, cycle,
                                          st.mapped_count,
                                          upper_pages_ll, lower_pages_ll,
                                          &fill_since_pause, fill_step_pages,
                                          marks_pages, marks_count,
                                          &fill_next_mark) != 0) {
                goto done;
            }
        }

        // Random 4KB unmap down to lower.
        long long drain_since_pause = 0;
        int drain_mark_idx = marks_count - 1;
        while (drain_mark_idx >= 0 && marks_pages[drain_mark_idx] >= st.mapped_count) {
            drain_mark_idx--;
        }

        int drain_fail_streak = 0;
        while (st.mapped_count > lower_pages_ll && !g_stop) {
            int idx = rand() % st.mapped_count;
            int pid = st.pages[idx];

            if (unmap_4k_page(&st, pid) != 0) {
                drain_fail_streak++;
                if (drain_fail_streak > 100000) {
                    fprintf(stderr, "drain: too many munmap failures, stopping drain\n");
                    break;
                }
                continue;
            }

            drain_fail_streak = 0;
            drain_since_pause++;
            if (maybe_trigger_drain_pauses(&pause_idx, cycle,
                                           st.mapped_count,
                                           upper_pages_ll, lower_pages_ll,
                                           &drain_since_pause, drain_step_pages,
                                           marks_pages, &drain_mark_idx) != 0) {
                goto done;
            }
        }
    }

done:
    printf("DONE allocated_pages=%d allocated_kb=%lld\n",
           st.mapped_count, (long long)st.mapped_count * 4);
    fflush(stdout);

    arena_destroy(&st);
    return 0;
}
