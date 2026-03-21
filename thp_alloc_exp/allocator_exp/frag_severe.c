#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define HUGE_PAGE_SIZE (2 << 20)              // 2MB
#define SMALL_PAGE_SIZE (4 << 10)             // 4KB
#define PAGES_PER_HUGE (HUGE_PAGE_SIZE / SMALL_PAGE_SIZE)  // 512

typedef struct chunk_info {
    void *addr;
    char *page_map;
    int pages_allocated;
    struct chunk_info *next;
} chunk_info;

enum free_policy_mode {
    FREE_POLICY_FULL_FIRST = 0,
    FREE_POLICY_PINS_FIRST = 1,
};

static const char *free_policy_name(enum free_policy_mode mode)
{
    return mode == FREE_POLICY_PINS_FIRST ? "pins_first" : "full_first";
}

static int parse_free_policy(const char *s, enum free_policy_mode *mode)
{
    if (strcmp(s, "full_first") == 0) {
        *mode = FREE_POLICY_FULL_FIRST;
        return 0;
    }
    if (strcmp(s, "pins_first") == 0) {
        *mode = FREE_POLICY_PINS_FIRST;
        return 0;
    }
    return -1;
}

static void usage(const char *prog, FILE *out)
{
    fprintf(out, "usage: %s allocsize targetsize [pin_density] [cycles] [free_policy]\n", prog);
    fprintf(out, "  allocsize       - hard cap to fill in each cycle: kbytes, or number[KMGP]\n");
    fprintf(out, "  targetsize      - memory to keep after each drain phase\n");
    fprintf(out, "  pin_density     - pages between pins (default: 16 = 1 pin every 64KB)\n");
    fprintf(out, "  cycles          - oscillation cycles (default: 5)\n");
    fprintf(out, "  free_policy     - full_first | pins_first (default: full_first)\n");
    fprintf(out, "\nStrategy:\n");
    fprintf(out, "  1. Fill to allocsize (huge-first, then 4KB fallback)\n");
    fprintf(out, "  2. Drain to targetsize with regular pin spacing (policy-controlled)\n");
    fprintf(out, "  3. Repeat for N cycles, then hold\n");
    fprintf(out, "  4. Chunk metadata grows on demand (no fixed chunk cap)\n");
    fprintf(out, "\nExample: %s 9G 5G 128 5 pins_first\n", prog);
    exit(out == stderr);
}

static void usr_handler(int signal)
{
    (void)signal;
    printf("\nCaught signal, exiting...\n");
    exit(0);
}

static long long parse_size(const char *str)
{
    char *end = NULL;
    long long size = strtoull(str, &end, 0);

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

static int count_chunks(chunk_info *head)
{
    int n = 0;
    for (chunk_info *c = head; c != NULL; c = c->next) {
        n++;
    }
    return n;
}

static chunk_info *create_chunk(chunk_info **head)
{
    chunk_info *c = mmap(NULL, sizeof(*c),
                         PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (c == MAP_FAILED) {
        return NULL;
    }
    memset(c, 0, sizeof(*c));

    c->page_map = mmap(NULL, PAGES_PER_HUGE,
                       PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
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
    chunk->addr = mmap(NULL, HUGE_PAGE_SIZE,
                       PROT_READ | PROT_WRITE,
                       MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
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

static long long fill_chunk_holes(chunk_info *chunk, long long need_pages)
{
    long long added = 0;

    if (chunk->addr == NULL || need_pages <= 0) {
        return 0;
    }

    for (int j = 0; j < PAGES_PER_HUGE && added < need_pages; j++) {
        if (chunk->page_map[j]) {
            continue;
        }

        void *page_addr = (char *)chunk->addr + ((size_t)j * SMALL_PAGE_SIZE);
        void *result = mmap(page_addr, SMALL_PAGE_SIZE,
                            PROT_READ | PROT_WRITE,
                            MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED,
                            -1, 0);
        if (result == MAP_FAILED) {
            continue;
        }

        *(char *)page_addr = 1;
        chunk->page_map[j] = 1;
        chunk->pages_allocated++;
        added++;
    }

    return added;
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
            perror("munmap while trimming");
            exit(1);
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

static int free_full_chunk(chunk_info *chunk)
{
    if (chunk->addr == NULL || chunk->pages_allocated != PAGES_PER_HUGE) {
        return 0;
    }

    if (munmap(chunk->addr, HUGE_PAGE_SIZE) != 0) {
        return 0;
    }

    memset(chunk->page_map, 0, PAGES_PER_HUGE);
    chunk->addr = NULL;
    chunk->pages_allocated = 0;
    return 1;
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

static void print_pin_histogram(chunk_info *head)
{
    int pins_per_chunk[10] = {0};

    for (chunk_info *c = head; c != NULL; c = c->next) {
        if (c->addr == NULL) {
            continue;
        }
        if (c->pages_allocated <= 0 || c->pages_allocated >= PAGES_PER_HUGE) {
            continue;
        }

        int bucket = c->pages_allocated / 50;
        if (bucket > 9) {
            bucket = 9;
        }
        pins_per_chunk[bucket]++;
    }

    printf("Chunks with scattered pins (prevents coalescing):\n");
    for (int i = 0; i < 10; i++) {
        if (pins_per_chunk[i] > 0) {
            printf("  %d-%d pages: %d chunks\n",
                   i * 50, (i + 1) * 50 - 1, pins_per_chunk[i]);
        }
    }
}

int main(int argc, char *argv[])
{
    long long requested_total_bytes = 0, requested_target_bytes = 0;
    long long total_pages = 0, target_pages = 0;
    int target_percent, pin_density = 16, num_cycles = 5;
    enum free_policy_mode free_policy = FREE_POLICY_FULL_FIRST;
    chunk_info *chunks = NULL;
    struct sigaction sa;

    if (argc < 3) {
        usage(argv[0], stderr);
    }

    requested_total_bytes = parse_size(argv[1]);
    if (requested_total_bytes <= 0) {
        fprintf(stderr, "Error: invalid allocsize format\n");
        usage(argv[0], stderr);
    }

    requested_target_bytes = parse_size(argv[2]);
    if (requested_target_bytes <= 0) {
        fprintf(stderr, "Error: invalid targetsize format\n");
        usage(argv[0], stderr);
    }

    if (argc >= 4) {
        pin_density = atoi(argv[3]);
        if (pin_density < 4 || pin_density > 1280) {
            fprintf(stderr, "Error: pin_density must be between 4-1280\n");
            exit(1);
        }
    }

    if (argc >= 5) {
        num_cycles = atoi(argv[4]);
        if (num_cycles < 1) {
            fprintf(stderr, "Error: cycles must be at least 1\n");
            exit(1);
        }
    }

    if (argc >= 6) {
        if (parse_free_policy(argv[5], &free_policy) != 0) {
            fprintf(stderr, "Error: free_policy must be full_first or pins_first\n");
            exit(1);
        }
    }

    total_pages = requested_total_bytes / SMALL_PAGE_SIZE;
    if (total_pages <= 0) {
        fprintf(stderr, "Error: allocsize is smaller than one small page (4KB)\n");
        exit(1);
    }
    target_pages = requested_target_bytes / SMALL_PAGE_SIZE;

    if (target_pages <= 0) {
        fprintf(stderr, "Error: targetsize is smaller than one small page (4KB)\n");
        exit(1);
    }
    if (target_pages > total_pages) {
        fprintf(stderr,
                "Error: targetsize (%lld KB) cannot be larger than allocsize cap (%lld KB)\n",
                requested_target_bytes >> 10, requested_total_bytes >> 10);
        exit(1);
    }

    target_percent = (int)((target_pages * 100) / total_pages);

    printf("\n");
    printf("=============================================\n");
    printf("Memory Fragmentation Tool\n");
    printf("=============================================\n");
    printf("Fill cap:                %lld MB (%lld GB)\n",
           requested_total_bytes >> 20, requested_total_bytes >> 30);
    printf("Target drain size:       %lld MB (%lld GB) = %d%%\n",
           (target_pages * SMALL_PAGE_SIZE) >> 20,
           (target_pages * SMALL_PAGE_SIZE) >> 30,
           target_percent);
    printf("Cap pages (4KB):         %lld\n", total_pages);
    printf("Target pages:            %lld\n", target_pages);
    printf("Pin density:             1 pin every %d pages (%d KB)\n",
           pin_density, pin_density * 4);
    printf("Free policy:             %s\n", free_policy_name(free_policy));
    printf("Oscillation pattern:     fill cap <-> target\n");
    printf("Cycles:                  %d\n", num_cycles);
    printf("Chunk metadata cap:      unbounded (mmap on demand)\n");
    printf("=============================================\n");
    printf("\n");

    sa.sa_flags = 0;
    sa.sa_handler = usr_handler;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);

    srand((unsigned int)time(NULL));

    for (int cycle = 1; cycle <= num_cycles; cycle++) {
        long long current;
        long long to_allocate;
        long long allocated = 0;
        long long to_free;
        long long freed = 0;

        printf("\n");
        printf("=============================================\n");
        printf("CYCLE %d of %d\n", cycle, num_cycles);
        printf("=============================================\n");

        // PHASE A: fill to hard cap with huge-first strategy.
        printf("\n--- Phase A: Fill to cap (%lld MB) ---\n", requested_total_bytes >> 20);
        current = count_total_pages(chunks);
        to_allocate = total_pages - current;

        printf("Current: %lld pages (%.1f%%) = %lld MB\n",
               current, (current * 100.0) / total_pages,
               (current * SMALL_PAGE_SIZE) >> 20);
        printf("Target:  %lld pages (100%%) = %lld MB\n",
               total_pages, (total_pages * SMALL_PAGE_SIZE) >> 20);

        if (to_allocate > 0) {
            long long full_chunk_added = 0;
            long long hole_added = 0;

            // Pass 1A: consume already-empty chunk slots first.
            for (chunk_info *c = chunks; c != NULL && allocated < to_allocate; c = c->next) {
                if (c->addr != NULL || (to_allocate - allocated) < PAGES_PER_HUGE) {
                    continue;
                }
                if (alloc_full_chunk(c)) {
                    allocated += PAGES_PER_HUGE;
                    full_chunk_added += PAGES_PER_HUGE;
                }
            }

            // Pass 1B: add chunk metadata on demand.
            while ((to_allocate - allocated) >= PAGES_PER_HUGE) {
                chunk_info *c = create_chunk(&chunks);
                if (!c) {
                    break;
                }
                if (!alloc_full_chunk(c)) {
                    break;
                }
                allocated += PAGES_PER_HUGE;
                full_chunk_added += PAGES_PER_HUGE;
            }

            // Pass 2: handle sub-2MB remainder with a fresh full chunk + trim.
            if (allocated < to_allocate) {
                chunk_info *c = NULL;
                for (chunk_info *it = chunks; it != NULL; it = it->next) {
                    if (it->addr == NULL) {
                        c = it;
                        break;
                    }
                }
                if (c == NULL) {
                    c = create_chunk(&chunks);
                }

                if (c && alloc_full_chunk(c)) {
                    long long need = to_allocate - allocated;
                    long long trim = PAGES_PER_HUGE - need;
                    if (need < PAGES_PER_HUGE) {
                        if (trim_chunk_pages(c, trim) != trim) {
                            fprintf(stderr, "Error: failed to trim partial fill chunk\n");
                            exit(1);
                        }
                    }
                    allocated += need;
                    full_chunk_added += need;
                }
            }

            // Pass 3 (fallback): only if still short, refill holes with 4KB pages.
            for (chunk_info *c = chunks; c != NULL && allocated < to_allocate; c = c->next) {
                long long added_now;
                if (c->addr == NULL || c->pages_allocated == PAGES_PER_HUGE) {
                    continue;
                }
                added_now = fill_chunk_holes(c, to_allocate - allocated);
                allocated += added_now;
                hole_added += added_now;
            }

            if (allocated < to_allocate) {
                printf("Warning: could not reach full cap in this cycle (missing %lld pages)\n",
                       to_allocate - allocated);
            }

            printf("Allocated %lld pages (%lld MB)\n",
                   allocated, (allocated * SMALL_PAGE_SIZE) >> 20);
            printf("Phase A detail: full-chunk=%lld pages (%lld MB), hole-refill=%lld pages (%lld MB)\n",
                   full_chunk_added, (full_chunk_added * SMALL_PAGE_SIZE) >> 20,
                   hole_added, (hole_added * SMALL_PAGE_SIZE) >> 20);
        }

        current = count_total_pages(chunks);
        printf("Phase A complete: %lld pages (%.1f%%) = %lld MB\n\n",
               current, (current * 100.0) / total_pages,
               (current * SMALL_PAGE_SIZE) >> 20);

        sleep(1);

        // PHASE B: drain to target while keeping regular pins.
        printf("--- Phase B: Drain to target (%lld MB) with regular pins ---\n",
               (target_pages * SMALL_PAGE_SIZE) >> 20);
        printf("Pin strategy: Keep 1 page every %d pages (regular grid)\n", pin_density);

        to_free = current - target_pages;
        if (to_free < 0) {
            to_free = 0;
        }

        printf("Current: %lld pages = %lld MB\n", current, (current * SMALL_PAGE_SIZE) >> 20);
        printf("Target:  %lld pages = %lld MB\n", target_pages, (target_pages * SMALL_PAGE_SIZE) >> 20);
        printf("To free: %lld pages = %lld MB\n", to_free, (to_free * SMALL_PAGE_SIZE) >> 20);

        if (to_free > 0) {
            if (free_policy == FREE_POLICY_PINS_FIRST) {
                for (chunk_info *c = chunks; c != NULL && freed < to_free; c = c->next) {
                    if (c->addr == NULL) {
                        continue;
                    }
                    freed += free_chunk_with_pins(c, to_free - freed, pin_density);
                }
            }

            if (free_policy == FREE_POLICY_FULL_FIRST || freed < to_free) {
                // full_first policy, or fallback if pins_first still needs more free pages
                while ((to_free - freed) >= PAGES_PER_HUGE) {
                    int dropped = 0;
                    for (chunk_info *c = chunks; c != NULL; c = c->next) {
                        if (free_full_chunk(c)) {
                            freed += PAGES_PER_HUGE;
                            dropped = 1;
                            break;
                        }
                    }
                    if (!dropped) {
                        break;
                    }
                }
            }

            if (free_policy == FREE_POLICY_FULL_FIRST) {
                for (chunk_info *c = chunks; c != NULL; c = c->next) {
                    if (c->addr == NULL || freed >= to_free) {
                        continue;
                    }
                    freed += free_chunk_with_pins(c, to_free - freed, pin_density);
                }
            }

            if (free_policy == FREE_POLICY_PINS_FIRST && freed < to_free) {
                for (chunk_info *c = chunks; c != NULL && freed < to_free; c = c->next) {
                    if (c->addr == NULL) {
                        continue;
                    }
                    freed += free_chunk_with_pins(c, to_free - freed, pin_density);
                }
            }

            if (freed < to_free) {
                printf("Warning: could not drain to target in this cycle (remaining %lld pages)\n",
                       to_free - freed);
            }
        }

        current = count_total_pages(chunks);
        printf("Phase B complete: %lld pages (%.1f%%) = %lld MB\n",
               current, (current * 100.0) / total_pages,
               (current * SMALL_PAGE_SIZE) >> 20);

        printf("\n--- Cycle %d Summary ---\n", cycle);
        print_pin_histogram(chunks);
        printf("Total chunk metadata objects: %d\n", count_chunks(chunks));

        if (cycle < num_cycles) {
            printf("\nWaiting before next cycle...\n");
            sleep(2);
        }
    }

    long long final = count_total_pages(chunks);

    int chunks_full = 0, chunks_pins = 0, chunks_empty = 0;
    long long total_pin_pages = 0;
    for (chunk_info *c = chunks; c != NULL; c = c->next) {
        if (c->addr == NULL || c->pages_allocated == 0) {
            chunks_empty++;
        } else if (c->pages_allocated == PAGES_PER_HUGE) {
            chunks_full++;
        } else {
            chunks_pins++;
            total_pin_pages += c->pages_allocated;
        }
    }

    printf("\n");
    printf("=============================================\n");
    printf("FRAGMENTATION LOCKED\n");
    printf("=============================================\n");
    printf("Fill cap:                %lld pages = %lld MB\n",
           total_pages, (total_pages * SMALL_PAGE_SIZE) >> 20);
    printf("Final allocated:         %lld pages = %lld MB (%.1f%%)\n",
           final, (final * SMALL_PAGE_SIZE) >> 20, (final * 100.0) / total_pages);
    printf("Target was:              %lld pages = %lld MB\n",
           target_pages, (target_pages * SMALL_PAGE_SIZE) >> 20);
    printf("\n");
    printf("Chunk breakdown:\n");
    printf("  Full chunks:           %d\n", chunks_full);
    printf("  Chunks with pins:      %d (%.1f avg pins/chunk)\n",
           chunks_pins, chunks_pins > 0 ? (total_pin_pages * 1.0) / chunks_pins : 0.0);
    printf("  Empty chunks:          %d\n", chunks_empty);
    printf("\n");
    printf("Fragmentation details:\n");
    printf("  - %d chunks have scattered pin pages\n", chunks_pins);
    printf("  - Pins placed every %d pages (grid pattern)\n", pin_density);
    printf("  - Free policy: %s\n", free_policy_name(free_policy));
    printf("  - %d fragmentation cycles applied\n", num_cycles);
    printf("=============================================\n");
    printf("\n");

    printf("Verify fragmentation persists:\n");
    printf("  cat /proc/buddyinfo | grep Normal\n");
    printf("  -> Order 9-10 should be LOW\n");
    printf("\n");
    printf("Holding %lld MB of fragmented memory...\n", (final * SMALL_PAGE_SIZE) >> 20);
    printf("Press Ctrl+C to exit.\n\n");
    fflush(stdout);

    while (1) {
        sleep(60);
        printf("[Status] Holding %lld MB (%.1f%%), %d chunks with pins\n",
               (final * SMALL_PAGE_SIZE) >> 20,
               (final * 100.0) / total_pages,
               chunks_pins);
    }

    return 0;
}
