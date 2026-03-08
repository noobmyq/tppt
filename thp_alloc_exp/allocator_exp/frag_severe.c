#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/time.h>
#include <signal.h>
#include <err.h>
#include <fcntl.h>

#define HUGE_PAGE_SIZE (2 << 20)  // 2MB
#define SMALL_PAGE_SIZE (4 << 10)  // 4KB
#define PAGES_PER_HUGE (HUGE_PAGE_SIZE / SMALL_PAGE_SIZE)  // 512

typedef unsigned int uint32_t;

void usage(const char *prog, FILE *out)
{
	fprintf(out, "usage: %s allocsize targetsize [pin_density] [cycles]\n", prog);
	fprintf(out, "  allocsize       - total memory to allocate: kbytes, or number[KMGP]\n");
	fprintf(out, "  targetsize      - final memory to keep: kbytes, or number[KMGP]\n");
	fprintf(out, "  pin_density     - pages between pins (default: 16 = 1 pin every 64KB)\n");
	fprintf(out, "  cycles          - oscillation cycles (default: 5)\n");
	fprintf(out, "\nStrategy:\n");
	fprintf(out, "  1. Allocate to 80%% of allocsize\n");
	fprintf(out, "  2. Free to 40%% with regular pin spacing\n");
	fprintf(out, "  3. Repeat to accumulate fragmentation\n");
	fprintf(out, "  4. Finally adjust to targetsize and hold\n");
	fprintf(out, "\nExample: %s 8G 4G 16 5\n", prog);
	fprintf(out, "  Allocate 8GB capacity, keep 4GB final, 1 pin every 16 pages, 5 cycles\n");
	fprintf(out, "\nExample: %s 10G 7G 8 10\n", prog);
	fprintf(out, "  Allocate 10GB capacity, keep 7GB final, denser pins, 10 cycles\n");
	exit(out == stderr);
}

void usr_handler(int signal) 
{
	printf("\nCaught signal, exiting...\n");
	exit(0);
}

typedef struct {
	void *addr;
	char *page_map;
	int pages_allocated;
} chunk_info;

static uint32_t random_range(uint32_t a, uint32_t b) {
	uint32_t v, range, upper, lower, mask;
	if(a == b) return a;
	if(a > b) { upper = a; lower = b; }
	else { upper = b; lower = a; }
	range = upper - lower;
	mask = 0;
	while(1) {
		if(mask >= range) break;
		mask = (mask << 1) | 1;
	}
	while(1) {
		v = rand() & mask;
		if(v <= range) return lower + v;
	}
}

long long count_total_pages(chunk_info *chunks, int numchunk) {
	long long total = 0;
	for (int i = 0; i < numchunk; i++) {
		if (chunks[i].addr != NULL) {
			total += chunks[i].pages_allocated;
		}
	}
	return total;
}

long long parse_size(const char *str) {
	char *end = NULL;
	long long size = strtoull(str, &end, 0);
	switch(*end) {
		case 'g':
		case 'G':
			size *= 1024;
		case 'm':
		case 'M':
			size *= 1024;
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

int main(int argc, char *argv[])
{
	long long kbtotal = 0, kbtarget = 0;
	int i, j, numchunk, target_percent, pin_density = 16, num_cycles = 5;
	chunk_info *chunks;
	struct sigaction sa;
	
	// Parse arguments
	if (argc < 3) {
		usage(argv[0], stderr);
	}
	
	// Parse total allocation size
	kbtotal = parse_size(argv[1]) * 5 / 4;
	if (kbtotal <= 0) {
		fprintf(stderr, "Error: invalid allocsize format\n");
		usage(argv[0], stderr);
	}
	
	// Parse target size
	kbtarget = parse_size(argv[2]);
	if (kbtarget <= 0) {
		fprintf(stderr, "Error: invalid targetsize format\n");
		usage(argv[0], stderr);
	}
	
	if (kbtarget > kbtotal) {
		fprintf(stderr, "Error: targetsize (%lld KB) cannot be larger than allocsize (%lld KB)\n", 
		        kbtarget, kbtotal);
		exit(1);
	}
	
	// Calculate target percentage
	target_percent = (int)((kbtarget * 100) / kbtotal);
	
	if (target_percent < 10) {
		fprintf(stderr, "Error: targetsize is too small (<%d%% of allocsize)\n", 10);
		exit(1);
	}
	
	if (argc >= 4) {
		pin_density = atoi(argv[3]);
		if (pin_density < 4 || pin_density > 1280) {
			fprintf(stderr, "Error: pin_density must be between 4-128\n");
			exit(1);
		}
	}
	
	if (argc >= 5) {
		num_cycles = atoi(argv[4]);
		/*if (num_cycles < 1) {
			fprintf(stderr, "Error: cycles must be at least 1\n");
			exit(1);
		}*/
	}
	
	numchunk = kbtotal / HUGE_PAGE_SIZE;
	if (numchunk == 0) {
		fprintf(stderr, "Error: allocation too small\n");
		exit(1);
	}
	
	long long total_pages = (long long)numchunk * PAGES_PER_HUGE;
	long long target_pages = (total_pages * target_percent) / 100;
	
	printf("\n");
	printf("=============================================\n");
	printf("Memory Fragmentation Tool\n");
	printf("=============================================\n");
	printf("Total capacity:         %lld MB (%lld GB)\n", kbtotal >> 10, kbtotal >> 20);
	printf("Target final size:      %lld MB (%lld GB) = %d%%\n", 
	       kbtarget >> 10, kbtarget >> 20, target_percent);
	printf("Total 4KB pages:        %lld\n", total_pages);
	printf("Target pages:           %lld\n", target_pages);
	printf("Pin density:            1 pin every %d pages (%d KB)\n", 
	       pin_density, pin_density * 4);
	printf("Oscillation pattern:    80%% ↔ 40%%\n");
	printf("Cycles:                 %d\n", num_cycles);
	printf("=============================================\n");
	printf("\n");
	
	// Allocate structures
	chunks = mmap(0, sizeof(chunk_info) * numchunk, 
	              PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (chunks == MAP_FAILED) {
		perror("Failed to allocate tracking array");
		exit(1);
	}
	memset(chunks, 0, sizeof(chunk_info) * numchunk);
	
	for (i = 0; i < numchunk; i++) {
		chunks[i].page_map = malloc(PAGES_PER_HUGE);
		if (!chunks[i].page_map) {
			perror("Failed to allocate page map");
			exit(1);
		}
		memset(chunks[i].page_map, 0, PAGES_PER_HUGE);
	}
	
	sa.sa_flags = 0;
	sa.sa_handler = usr_handler;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGUSR1, &sa, NULL);
	
	srand(time(NULL));
	
	// OSCILLATION CYCLES
	for (int cycle = 1; cycle <= num_cycles; cycle++) {
		printf("\n");
		printf("=============================================\n");
		printf("CYCLE %d of %d\n", cycle, num_cycles);
		printf("=============================================\n");
		
		// PHASE A: Allocate to 80%
		printf("\n--- Phase A: Allocating to 80%% ---\n");
		
		long long target_80 = (total_pages * 80) / 100;
		long long current = count_total_pages(chunks, numchunk);
		long long to_allocate = target_80 - current;
		
		printf("Current: %lld pages (%.1f%%) = %lld MB\n", 
		       current, (current * 100.0) / total_pages,
		       (current * SMALL_PAGE_SIZE) >> 20);
		printf("Target:  %lld pages (80%%) = %lld MB\n", 
		       target_80, (target_80 * SMALL_PAGE_SIZE) >> 20);
		
		if (to_allocate > 0) {
			long long allocated = 0;
			
			for (i = 0; i < numchunk && allocated < to_allocate; i++) {
				if (chunks[i].addr == NULL) {
					chunks[i].addr = mmap(NULL, HUGE_PAGE_SIZE, 
					                     PROT_READ | PROT_WRITE,
					                     MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
					if (chunks[i].addr == MAP_FAILED || !chunks[i].addr) {
						chunks[i].addr = NULL;
						continue;
					}
					
					madvise(chunks[i].addr, HUGE_PAGE_SIZE, MADV_HUGEPAGE);
					memset(chunks[i].addr, 1, HUGE_PAGE_SIZE);
					memset(chunks[i].page_map, 1, PAGES_PER_HUGE);
					chunks[i].pages_allocated = PAGES_PER_HUGE;
					allocated += PAGES_PER_HUGE;
				} else {
					for (j = 0; j < PAGES_PER_HUGE && allocated < to_allocate; j++) {
						if (!chunks[i].page_map[j]) {
							void *page_addr = chunks[i].addr + (j * SMALL_PAGE_SIZE);
							void *result = mmap(page_addr, SMALL_PAGE_SIZE,
							                   PROT_READ | PROT_WRITE,
							                   MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED,
							                   -1, 0);
							if (result != MAP_FAILED) {
								*(char*)page_addr = 1;
								chunks[i].page_map[j] = 1;
								chunks[i].pages_allocated++;
								allocated++;
							}
						}
					}
				}
			}
			printf("Allocated %lld pages (%lld MB)\n", allocated, (allocated * SMALL_PAGE_SIZE) >> 20);
		}
		
		current = count_total_pages(chunks, numchunk);
		printf("Phase A complete: %lld pages (%.1f%%) = %lld MB\n\n",
		       current, (current * 100.0) / total_pages,
		       (current * SMALL_PAGE_SIZE) >> 20);
		
		sleep(1);
		
		// PHASE B: Free to 40% with REGULAR pin spacing
		printf("--- Phase B: Freeing to 40%% with regular pins ---\n");
		printf("Pin strategy: Keep 1 page every %d pages (regular grid)\n", pin_density);
		
		long long target_40 = (total_pages * 40) / 100;
		long long to_free = current - target_40;
		
		printf("Current: %lld pages = %lld MB\n", current, (current * SMALL_PAGE_SIZE) >> 20);
		printf("Target:  %lld pages (40%%) = %lld MB\n", 
		       target_40, (target_40 * SMALL_PAGE_SIZE) >> 20);
		printf("To free: %lld pages = %lld MB\n", to_free, (to_free * SMALL_PAGE_SIZE) >> 20);
		
		long long freed = 0;
		
		// Strategy: In each chunk, keep pins at regular intervals
		for (i = 0; i < numchunk && freed < to_free; i++) {
			if (chunks[i].addr == NULL) continue;
			
			// Determine pin positions (regular grid)
			char keep_pattern[PAGES_PER_HUGE];
			memset(keep_pattern, 0, PAGES_PER_HUGE);
			
			// Place pins at regular intervals
			for (j = 0; j < PAGES_PER_HUGE; j += pin_density) {
				keep_pattern[j] = 1;  // Keep this page as a pin
				// Also keep a few random neighbors to increase density
				if (j + 1 < PAGES_PER_HUGE && rand() % 100 < 30) {
					keep_pattern[j + 1] = 1;
				}
			}
			
			// Free pages that aren't pins
			for (j = 0; j < PAGES_PER_HUGE && freed < to_free; j++) {
				if (chunks[i].page_map[j] && !keep_pattern[j]) {
					void *page_addr = chunks[i].addr + (j * SMALL_PAGE_SIZE);
					if (munmap(page_addr, SMALL_PAGE_SIZE) == 0) {
						chunks[i].page_map[j] = 0;
						chunks[i].pages_allocated--;
						freed++;
					}
				}
			}
		}
		
		current = count_total_pages(chunks, numchunk);
		printf("Phase B complete: %lld pages (%.1f%%) = %lld MB\n",
		       current, (current * 100.0) / total_pages,
		       (current * SMALL_PAGE_SIZE) >> 20);
		
		// Count pins
		int pins_per_chunk[10] = {0};
		for (i = 0; i < numchunk; i++) {
			if (chunks[i].addr != NULL && chunks[i].pages_allocated > 0 && 
			    chunks[i].pages_allocated < PAGES_PER_HUGE) {
				int bucket = chunks[i].pages_allocated / 50;
				if (bucket > 9) bucket = 9;
				pins_per_chunk[bucket]++;
			}
		}
		
		printf("\n--- Cycle %d Summary ---\n", cycle);
		printf("Chunks with scattered pins (prevents coalescing):\n");
		for (i = 0; i < 10; i++) {
			if (pins_per_chunk[i] > 0) {
				printf("  %d-%d pages: %d chunks\n", 
				       i * 50, (i + 1) * 50 - 1, pins_per_chunk[i]);
			}
		}
		
		if (cycle < num_cycles) {
			printf("\nWaiting before next cycle...\n");
			sleep(2);
		}
	}
	
	// FINAL ADJUSTMENT to target size
	printf("\n");
	printf("=============================================\n");
	printf("FINAL ADJUSTMENT TO TARGET SIZE\n");
	printf("=============================================\n");
	
	long long current = count_total_pages(chunks, numchunk);
	long long target_final = target_pages;
	
	printf("Current: %lld pages (%.1f%%) = %lld MB\n", 
	       current, (current * 100.0) / total_pages,
	       (current * SMALL_PAGE_SIZE) >> 20);
	printf("Target:  %lld pages (%d%%) = %lld MB\n", 
	       target_final, target_percent,
	       (target_final * SMALL_PAGE_SIZE) >> 20);
	
	if (current < target_final) {
		long long to_add = target_final - current;
		long long added = 0;
		
		printf("Need to add %lld pages (%lld MB)...\n", 
		       to_add, (to_add * SMALL_PAGE_SIZE) >> 20);
		
		for (i = 0; i < numchunk && added < to_add; i++) {
			if (chunks[i].addr == NULL) {
				chunks[i].addr = mmap(NULL, HUGE_PAGE_SIZE, 
				                     PROT_READ | PROT_WRITE,
				                     MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
				if (chunks[i].addr != MAP_FAILED && chunks[i].addr != NULL) {
					madvise(chunks[i].addr, HUGE_PAGE_SIZE, MADV_HUGEPAGE);
					memset(chunks[i].addr, 1, HUGE_PAGE_SIZE);
					memset(chunks[i].page_map, 1, PAGES_PER_HUGE);
					chunks[i].pages_allocated = PAGES_PER_HUGE;
					added += PAGES_PER_HUGE;
				}
			} else {
				for (j = 0; j < PAGES_PER_HUGE && added < to_add; j++) {
					if (!chunks[i].page_map[j]) {
						void *page_addr = chunks[i].addr + (j * SMALL_PAGE_SIZE);
						void *result = mmap(page_addr, SMALL_PAGE_SIZE,
						                   PROT_READ | PROT_WRITE,
						                   MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED,
						                   -1, 0);
						if (result != MAP_FAILED) {
							*(char*)page_addr = 1;
							chunks[i].page_map[j] = 1;
							chunks[i].pages_allocated++;
							added++;
						}
					}
				}
			}
		}
		printf("Added %lld pages\n", added);
	} else if (current > target_final) {
		// Only free pages that aren't pins
		long long to_remove = current - target_final;
		long long removed = 0;
		
		printf("Need to remove %lld pages (%lld MB)...\n", 
		       to_remove, (to_remove * SMALL_PAGE_SIZE) >> 20);
		
		for (i = 0; i < numchunk && removed < to_remove; i++) {
			// Only remove from chunks that have > 50% allocated
			if (chunks[i].pages_allocated > PAGES_PER_HUGE / 2) {
				for (j = 0; j < PAGES_PER_HUGE && removed < to_remove; j++) {
					// Skip pins (every pin_density pages)
					if (j % pin_density != 0 && chunks[i].page_map[j]) {
						void *page_addr = chunks[i].addr + (j * SMALL_PAGE_SIZE);
						if (munmap(page_addr, SMALL_PAGE_SIZE) == 0) {
							chunks[i].page_map[j] = 0;
							chunks[i].pages_allocated--;
							removed++;
						}
					}
				}
			}
		}
		printf("Removed %lld pages\n", removed);
	}
	
	long long final = count_total_pages(chunks, numchunk);
	
	// Final stats
	int chunks_full = 0, chunks_pins = 0, chunks_empty = 0;
	long long total_pin_pages = 0;
	
	for (i = 0; i < numchunk; i++) {
		if (chunks[i].addr != NULL) {
			if (chunks[i].pages_allocated == PAGES_PER_HUGE) {
				chunks_full++;
			} else if (chunks[i].pages_allocated == 0) {
				chunks_empty++;
			} else {
				chunks_pins++;
				total_pin_pages += chunks[i].pages_allocated;
			}
		}
	}
	
	printf("\n");
	printf("=============================================\n");
	printf("FRAGMENTATION LOCKED\n");
	printf("=============================================\n");
	printf("Total capacity:         %lld pages = %lld MB\n", 
	       total_pages, (total_pages * SMALL_PAGE_SIZE) >> 20);
	printf("Final allocated:        %lld pages = %lld MB (%.1f%%)\n", 
	       final, (final * SMALL_PAGE_SIZE) >> 20, (final * 100.0) / total_pages);
	printf("Target was:             %lld MB (%d%%)\n", 
	       kbtarget >> 10, target_percent);
	printf("\n");
	printf("Chunk breakdown:\n");
	printf("  Full chunks:          %d\n", chunks_full);
	printf("  Chunks with pins:     %d (%.1f avg pins/chunk)\n", 
	       chunks_pins, chunks_pins > 0 ? (total_pin_pages * 1.0) / chunks_pins : 0);
	printf("  Empty chunks:         %d\n", chunks_empty);
	printf("\n");
	printf("Fragmentation details:\n");
	printf("  - %d chunks have scattered pin pages\n", chunks_pins);
	printf("  - Pins placed every %d pages (grid pattern)\n", pin_density);
	printf("  - %d fragmentation cycles applied\n", num_cycles);
	printf("=============================================\n");
	printf("\n");
	
	printf("Verify fragmentation persists:\n");
	printf("  cat /proc/buddyinfo | grep Normal\n");
	printf("  → Order 9-10 should be LOW\n");
	printf("\n");
	printf("Holding %lld MB of fragmented memory...\n", (final * SMALL_PAGE_SIZE) >> 20);
	printf("Press Ctrl+C to exit.\n\n");
    	fflush(stdout);	
	// Hold
	while(1) {
		sleep(60);
		printf("[Status] Holding %lld MB (%.1f%%), %d chunks with pins\n",
		       (final * SMALL_PAGE_SIZE) >> 20, 
		       (final * 100.0) / total_pages, chunks_pins);
	}
	
	return 0;
}