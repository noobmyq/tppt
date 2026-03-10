CC       := gcc

default_prefix := /usr/local
INCLUDE    := $(default_prefix)/include
LIBDIR     := $(default_prefix)/lib

CFLAGS   := -std=c11 -Wall -Wextra -O3 -fopenmp \
             -I$(INCLUDE)

TMPDIR ?= /users/LH/expr/.tmp
export TMPDIR


LDFLAGS  := -L$(LIBDIR) -Wl,-rpath,$(LIBDIR) \
             -lprealloc -lcontiguousMalloc

BLASLIBS := -lopenblas

SRC      := test.c gemv_cma.c
OBJ      := $(SRC:.c=.o)

NUMA_LIBS := -lnuma

.PHONY: all clean
all: vtest ctest mtest pagetest nmp_mig_reader nmp_block_table_test nmp_ring_decode_test

pagetest: page_migration_test.c
	$(CC) -O2 -Wall -Wextra -o $@ $< $(NUMA_LIBS)

blocktest: block_migration_test.c
	$(CC) -O2 -Wall -Wextra -o $@ $< $(NUMA_LIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJ) test gemv_cma mtest nmp_mig_reader nmp_mig_reader_dbg nmp_block_table_test nmp_ring_decode_test

