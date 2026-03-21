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

# go into /home/$USER/apps/redis and build as $USER

# build redis
chroot_run_as_user "cd /home/$USER/apps/redis && make && make bench_redis_st && cp bench_redis_st mosaictest"

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

sudo mkdir -p "$MNTPNT/home/$USER/thp_alloc_exp"
sudo cp -r "$BASE_DIR/thp_alloc_exp/allocator_exp" "$MNTPNT/home/$USER/thp_alloc_exp/allocator_exp"
chroot_run chown -R "$USER:$USER" "/home/$USER/thp_alloc_exp"

# build and install THP experiment binaries under /home/$USER/apps
chroot_run_as_user "gcc -O2 -Wall /home/$USER/thp_alloc_exp/allocator_exp/frag_severe.c -o /home/$USER/thp_alloc_exp/alloctest"
chroot_run_as_user "cp /home/$USER/mem-apps/xsbench/xsbench /home/$USER/thp_alloc_exp/tp_frag"
