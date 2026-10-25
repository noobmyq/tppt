#!/bin/bash

set -euo pipefail

TCMALLOC_ONLY=0
TCMALLOC_BFS_ONLY=0
case "${1:-}" in
    "") ;;
    --tcmalloc-only) TCMALLOC_ONLY=1 ;;
    --tcmalloc-bfs-only) TCMALLOC_BFS_ONLY=1 ;;
    *) echo "usage: $0 [--tcmalloc-only|--tcmalloc-bfs-only]" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    echo "usage: $0 [--tcmalloc-only|--tcmalloc-bfs-only]" >&2
    exit 2
fi

# make sure $MNTPNT is set
: "${MNTPNT:?MNTPNT not set}"
: "${USER:?USER not set}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
BASE_DIR=$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

# make sure mntpnt is mounted
if ! mountpoint -q -- "$MNTPNT"; then
    echo "$MNTPNT is not mounted. Please mount it before running this script."
    exit 1
fi

function chroot_run {
	sudo chroot "$MNTPNT" "$@"
}

function chroot_run_as_user {
    sudo chroot "$MNTPNT" /bin/su - "$USER" -s /bin/bash -c "set -euo pipefail; $*"
}

# The normal setup path provisions LLVM/Bazel/Google TCMalloc here, then
# builds all ten THP workloads in both variants below. Refresh staged helpers
# so older mounted images also use the current implementation.
sudo install -D -m 755 "$SCRIPT_DIR/setup-tcmalloc.sh" \
    "$MNTPNT/usr/local/sbin/tppt-setup-tcmalloc"
sudo install -D -m 755 "$SCRIPT_DIR/build-bfs-tcmalloc.sh" \
    "$MNTPNT/usr/local/sbin/tppt-build-bfs-tcmalloc"
sudo install -D -m 755 "$SCRIPT_DIR/build-thp-tcmalloc.sh" \
    "$MNTPNT/usr/local/sbin/tppt-build-thp-tcmalloc"
chroot_run /usr/local/sbin/tppt-setup-tcmalloc
if (( TCMALLOC_ONLY )); then
    exit 0
fi
if (( TCMALLOC_BFS_ONLY )); then
    chroot_run /usr/local/sbin/tppt-build-bfs-tcmalloc "$USER"
    exit 0
fi

# common libs
COMMON_LIBS=(
    libgomp1
    screen
    build-essential
    autoconf
    initramfs-tools
    time
    vim
    git
    libicu-dev
    pkg-config
    libevent-dev
    numactl
)

# redis libs
REDIS_LIBS=(
    libreadline-dev
)

# postgres libs
POSTGRES_LIBS=(
    zlib1g-dev
    bison
    flex
)


chroot_run apt-get update
chroot_run apt-get install -y ${COMMON_LIBS[@]} ${REDIS_LIBS[@]} ${POSTGRES_LIBS[@]}

# Build the reviewed microbenchmarks staged by setup-disk.sh.
chroot_run_as_user "cd /home/$USER/microbenchmark && make clean && make"
for binary in unit_fork_overhead unit_tppt_huge_fork unit_tppt_huge_shared; do
    chroot_run test -x "/home/$USER/microbenchmark/$binary"
done

# build redis
for redis_app in redis post-marker-redis; do
    chroot_run_as_user "cd /home/$USER/apps/$redis_app && make && make bench_redis_st && cp bench_redis_st mosaictest"
done

# build shmem_matmul    
chroot_run_as_user "cd /home/$USER/apps/shmem_matmu && make mem && cp mem mosaictest"

# build postgres
chroot_run_as_user "cd /home/$USER/apps/postgres && ./build.sh && ./simple-init.sh"

# then we build the OSv apps (for memory calculation)
chroot_run_as_user "cd /home/$USER/mem-apps/btree && make && cp BTree mosaictest"
chroot_run_as_user "cd /home/$USER/mem-apps/canneal && make module && cp canneal mosaictest"
chroot_run_as_user "cd /home/$USER/mem-apps/gups && make module && cp gups mosaictest"
chroot_run_as_user "cd /home/$USER/mem-apps/memcached-osv && ./autogen.sh && ./configure LDFLAGS=\"-static\" && make module && cp memcached mosaictest"
chroot_run_as_user "cd /home/$USER/mem-apps/xsbench && rm xsbench && make module && cp xsbench mosaictest"

# for graphbig
chroot_run_as_user "cd /home/$USER/mem-apps/graphbig/ && make module"
# we for loop the bin in graphbig/bin/* and then copy them to has prefix mosaictest
chroot_run_as_user "for bin in /home/$USER/mem-apps/graphbig/bin/*; do cp \"\$bin\" /home/$USER/mem-apps/graphbig/bin/mosaictest-\$(basename \"\$bin\"); done"

# Default setup always installs all 20 binaries: original allocator source
# for *_tcmalloc_2m, and the shift-23/cacheline patches for *_tcmalloc_8m.
# Both variants must pass their build and smoke/linkage checks first.
chroot_run /usr/local/sbin/tppt-build-thp-tcmalloc "$USER"

sudo mkdir -p "$MNTPNT/home/$USER/thp_alloc_exp"
sudo cp -r "$BASE_DIR/thp_alloc_exp/allocator_exp" "$MNTPNT/home/$USER/thp_alloc_exp/allocator_exp"
chroot_run chown -R "$USER:$USER" "/home/$USER/thp_alloc_exp"

# build and install THP experiment binaries under /home/$USER/apps
chroot_run_as_user "gcc -O2 -Wall /home/$USER/thp_alloc_exp/allocator_exp/frag_severe.c -o /home/$USER/thp_alloc_exp/alloctest"
chroot_run_as_user "cp /home/$USER/mem-apps/xsbench/xsbench /home/$USER/thp_alloc_exp/tp_frag"
