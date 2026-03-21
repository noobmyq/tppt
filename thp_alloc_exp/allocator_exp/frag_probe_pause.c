#include <ctype.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
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

typedef struct chunk_info {
    void *addr;
    char *page_map;
    int pages_allocated;
    struct chunk_info *next;
} chunk_info;

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int signo)
{
    (void)signo;
    g_stop = 1;
}

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
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

static long long count_total_pages(chunk_info *head)
{
    long long total = 0;
    for (chunk_info *c = head; c != NULL; c = c->next) {
        if (c->addr != NULL) {
            total += c->pages_allocated;
        }
    }
    return total;
}

static chunk_info *create_chunk(chunk_info **head)
{
    chunk_info *c = mmap(NULL, sizeof(*c), PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (c == MAP_FAILED) {
        return NULL;
    }
    memset(c, 0, sizeof(*c));

    c->page_map = mmap(NULL, PAGES_PER_HUGE, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (c->page_map == MAP_FAILED) {
        munmap(c, sizeof(*c));
        return NULL;
    }
    memset(c->page_map, 0, PAGES_PER_HUGE);

    c->next = *head;
    *head = c;
    return c;
}

static int alloc_full_chunk(chunk_info *chunk)
{
    chunk->addr = mmap(NULL, HUGE_PAGE_SIZE, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (chunk->addr == MAP_FAILED || chunk->addr == NULL) {
        chunk->addr = NULL;
        return 0;
    }

    (void)madvise(chunk->addr, HUGE_PAGE_SIZE, MADV_HUGEPAGE);
    memset(chunk->addr, 1, HUGE_PAGE_SIZE);
    memset(chunk->page_map, 1, PAGES_PER_HUGE);
    chunk->pages_allocated = PAGES_PER_HUGE;
    return 1;
}

static long long trim_chunk_pages(chunk_info *chunk, long long pages_to_trim)
{
    long long trimmed = 0;

    for (int j = PAGES_PER_HUGE - 1; j >= 0 && trimmed < pages_to_trim; j--) {
        if (!chunk->page_map[j]) {
            continue;
        }
        void *page_addr = (char *)chunk->addr + ((size_t)j * SMALL_PAGE_SIZE);
        if (munmap(page_addr, SMALL_PAGE_SIZE) != 0) {
            return trimmed;
        }
        chunk->page_map[j] = 0;
        chunk->pages_allocated--;
        trimmed++;
    }

    if (chunk->pages_allocated == 0) {
        chunk->addr = NULL;
    }

    return trimmed;
}

static long long free_chunk_with_pins(chunk_info *chunk, long long need_pages, int pin_density)
{
    char keep_pattern[PAGES_PER_HUGE];
    long long freed = 0;

    if (chunk->addr == NULL || need_pages <= 0) {
        return 0;
    }

    memset(keep_pattern, 0, sizeof(keep_pattern));
    for (int j = 0; j < PAGES_PER_HUGE; j += pin_density) {
        keep_pattern[j] = 1;
        if (j + 1 < PAGES_PER_HUGE && rand() % 100 < 30) {
            keep_pattern[j + 1] = 1;
        }
    }

    for (int j = 0; j < PAGES_PER_HUGE && freed < need_pages; j++) {
        if (!chunk->page_map[j] || keep_pattern[j]) {
            continue;
        }
        void *page_addr = (char *)chunk->addr + ((size_t)j * SMALL_PAGE_SIZE);
        if (munmap(page_addr, SMALL_PAGE_SIZE) != 0) {
            continue;
        }
        chunk->page_map[j] = 0;
        chunk->pages_allocated--;
        freed++;
    }

    if (chunk->pages_allocated == 0) {
        chunk->addr = NULL;
    }

    return freed;
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

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s allocsize targetsize pin_density cycles [fill_pause_hpages] [drain_pause_hpages] [pause_marks_csv]\n"
            "example: %s 9G 5G 128 5 10 10 1G,2G,3G\n",
            prog, prog);
    exit(1);
}

int main(int argc, char **argv)
{
    long long requested_total_bytes, requested_target_bytes;
    long long total_pages, target_pages;
    int pin_density, cycles;
    int fill_pause_hpages = 0;
    int drain_pause_hpages = 0;
    long long fill_step_pages, drain_step_pages;
    const char *pause_marks_csv = "";
    long long marks_pages[MAX_MARKS];
    int marks_count = 0;

    chunk_info *chunks = NULL;
    int pause_idx = 0;

    if (argc < 5) {
        usage(argv[0]);
    }

    requested_total_bytes = parse_size(argv[1]);
    requested_target_bytes = parse_size(argv[2]);
    pin_density = atoi(argv[3]);
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

    if (requested_total_bytes <= 0 || requested_target_bytes <= 0 ||
        pin_density < 4 || cycles < 1 ||
        fill_pause_hpages < 0 || drain_pause_hpages < 0) {
        usage(argv[0]);
    }

    total_pages = requested_total_bytes / SMALL_PAGE_SIZE;
    target_pages = requested_target_bytes / SMALL_PAGE_SIZE;
    if (target_pages <= 0 || target_pages > total_pages) {
        die("invalid sizes: target must be >0 and <= alloc cap");
    }

    fill_step_pages = (long long)fill_pause_hpages * PAGES_PER_HUGE;
    drain_step_pages = (long long)drain_pause_hpages * PAGES_PER_HUGE;
    marks_count = parse_pause_marks_csv(pause_marks_csv, marks_pages, MAX_MARKS, total_pages);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    srand((unsigned int)time(NULL));

    printf("frag_probe_pause start: pid=%d cap_pages=%lld target_pages=%lld pin=%d cycles=%d fill_step_hpages=%d drain_step_hpages=%d marks=%d\n",
           getpid(), total_pages, target_pages, pin_density, cycles,
           fill_pause_hpages, drain_pause_hpages, marks_count);
    if (marks_count > 0) {
        printf("pause_marks_pages:");
        for (int i = 0; i < marks_count; i++) {
            printf(" %lld", marks_pages[i]);
        }
        printf("\n");
    }
    fflush(stdout);

    for (int cycle = 1; cycle <= cycles && !g_stop; cycle++) {
        long long current = count_total_pages(chunks);
        long long to_allocate = total_pages - current;
        long long allocated_this_fill = 0;
        long long fill_since_pause = 0;
        int fill_next_mark = 0;

        while (fill_next_mark < marks_count && marks_pages[fill_next_mark] <= current) {
            fill_next_mark++;
        }

        while ((to_allocate - allocated_this_fill) >= PAGES_PER_HUGE && !g_stop) {
            chunk_info *c = NULL;
            for (chunk_info *it = chunks; it != NULL; it = it->next) {
                if (it->addr == NULL) {
                    c = it;
                    break;
                }
            }
            if (!c) {
                c = create_chunk(&chunks);
                if (!c) {
                    break;
                }
            }
            if (!alloc_full_chunk(c)) {
                break;
            }

            allocated_this_fill += PAGES_PER_HUGE;
            current += PAGES_PER_HUGE;
            fill_since_pause += PAGES_PER_HUGE;

            if (maybe_trigger_fill_pauses(&pause_idx, cycle, current,
                                          total_pages, target_pages,
                                          &fill_since_pause, fill_step_pages,
                                          marks_pages, marks_count,
                                          &fill_next_mark) != 0) {
                goto done;
            }
        }

        if (!g_stop && allocated_this_fill < to_allocate) {
            chunk_info *c = create_chunk(&chunks);
            if (c && alloc_full_chunk(c)) {
                long long need = to_allocate - allocated_this_fill;
                if (need < PAGES_PER_HUGE) {
                    long long trim = PAGES_PER_HUGE - need;
                    long long trimmed = trim_chunk_pages(c, trim);
                    long long added_now = PAGES_PER_HUGE - trimmed;
                    if (trimmed != trim) {
                        fprintf(stderr, "warning: partial trim mismatch (%lld/%lld)\n", trimmed, trim);
                    }

                    allocated_this_fill += added_now;
                    current += added_now;
                    fill_since_pause += added_now;
                } else {
                    allocated_this_fill += PAGES_PER_HUGE;
                    current += PAGES_PER_HUGE;
                    fill_since_pause += PAGES_PER_HUGE;
                }

                if (maybe_trigger_fill_pauses(&pause_idx, cycle, current,
                                              total_pages, target_pages,
                                              &fill_since_pause, fill_step_pages,
                                              marks_pages, marks_count,
                                              &fill_next_mark) != 0) {
                    goto done;
                }
            }
        }

        long long to_free = current - target_pages;
        if (to_free < 0) {
            to_free = 0;
        }

        long long freed = 0;
        long long drain_since_pause = 0;
        int drain_mark_idx = marks_count - 1;
        while (drain_mark_idx >= 0 && marks_pages[drain_mark_idx] >= current) {
            drain_mark_idx--;
        }

        long long prev_freed = -1;
        while (freed < to_free && !g_stop && prev_freed != freed) {
            prev_freed = freed;
            for (chunk_info *c = chunks; c != NULL && freed < to_free && !g_stop; c = c->next) {
                if (c->addr == NULL) {
                    continue;
                }

                long long freed_now = free_chunk_with_pins(c, to_free - freed, pin_density);
                if (freed_now <= 0) {
                    continue;
                }

                freed += freed_now;
                current -= freed_now;
                drain_since_pause += freed_now;

                if (maybe_trigger_drain_pauses(&pause_idx, cycle, current,
                                               total_pages, target_pages,
                                               &drain_since_pause, drain_step_pages,
                                               marks_pages, &drain_mark_idx) != 0) {
                    goto done;
                }
            }
        }
    }

done:
    {
        long long final_pages = count_total_pages(chunks);
        printf("DONE allocated_pages=%lld allocated_kb=%lld\n", final_pages, final_pages * 4);
        fflush(stdout);
    }

    return 0;
}
