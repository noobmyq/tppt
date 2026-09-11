#!/bin/bash

set -euo pipefail

# make sure $MNTPNT is set
: "${MNTPNT:?MNTPNT not set}"
: "${USER:?USER not set}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
BASE_DIR=$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

# make sure mntpnt is mounted
if ! grep -qs "$MNTPNT" /proc/mounts; then
    echo "$MNTPNT is not mounted. Please mount it before running this script."
    exit 1
fi

function chroot_run {
	sudo chroot $MNTPNT "$@"
}

function chroot_run_as_user {
    sudo chroot $MNTPNT /bin/su - $USER -c "$*"
}

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

# Build the fixed-v2 helper from the staged Linux source and install the exact
# binary used by both M14 shared-workload launchers.
chroot_run_as_user "make -C /home/$USER/tppt-m14/linux/tools/testing/tppt clean all"
chroot_run install -m 0755 \
    "/home/$USER/tppt-m14/linux/tools/testing/tppt/tppt_shared_probe" \
    /usr/local/bin/tppt_shared_probe

# build redis
for redis_app in redis post-marker-redis; do
    chroot_run_as_user "cd /home/$USER/apps/$redis_app && make && make bench_redis_st && cp bench_redis_st mosaictest"
done

# build shmem_matmul    
chroot_run_as_user "cd /home/$USER/apps/shmem_matmu && make mem && cp mem mosaictest"

# build postgres
chroot_run_as_user "cd /home/$USER/apps/postgres && ./build.sh && ./simple-init.sh"

# Preserve the original installation and dataset. Build the opt-in M14 copy in
# its separate path; prepare.sh verifies the original source manifest itself.
if chroot_run test -e "/home/$USER/apps/postgres-m14"; then
    echo "refusing to overwrite existing PostgreSQL M14 stage" >&2
    exit 1
fi
chroot_run_as_user \
    "/home/$USER/tppt-m14/postgres/prepare.sh --source /home/$USER/apps/postgres --stage /home/$USER/apps/postgres-m14"
chroot_run test -x "/home/$USER/apps/postgres-m14/build_dir/bin/postgres"
chroot_run test -x "/home/$USER/apps/postgres-m14/build_dir/bin/mosaictest"

# Keep a guest-local binding for the later host manifest. This records the
# exact staged sources and binaries without claiming runtime evidence.
chroot_run /bin/bash -c "sha256sum \
    /home/$USER/microbenchmark/tppt_huge_shared.c \
    /home/$USER/microbenchmark/unit_tppt_huge_shared \
    /home/$USER/tppt-m14/linux/tools/testing/tppt/tppt_shared_probe.c \
    /home/$USER/tppt-m14/linux/include/linux/tppt_shmem_probe.h \
    /usr/local/bin/tppt_shared_probe \
    /home/$USER/tppt-m14/postgres/prepare.sh \
    /home/$USER/tppt-m14/postgres/tppt-m14-postgres.patch \
    /home/$USER/apps/postgres-m14/build_dir/bin/postgres \
    > /home/$USER/tppt-m14/artifacts.sha256"
chroot_run chown "$USER:$USER" "/home/$USER/tppt-m14/artifacts.sha256"


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

sudo mkdir -p "$MNTPNT/home/$USER/thp_alloc_exp"
sudo cp -r "$BASE_DIR/thp_alloc_exp/allocator_exp" "$MNTPNT/home/$USER/thp_alloc_exp/allocator_exp"
chroot_run chown -R "$USER:$USER" "/home/$USER/thp_alloc_exp"

# build and install THP experiment binaries under /home/$USER/apps
chroot_run_as_user "gcc -O2 -Wall /home/$USER/thp_alloc_exp/allocator_exp/frag_severe.c -o /home/$USER/thp_alloc_exp/alloctest"
chroot_run_as_user "cp /home/$USER/mem-apps/xsbench/xsbench /home/$USER/thp_alloc_exp/tp_frag"
