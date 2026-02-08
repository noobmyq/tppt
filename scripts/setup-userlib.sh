#!/bin/bash

set -euo pipefail

# make sure $MNTPNT is set
: "${MNTPNT:?MNTPNT not set}"

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
chroot_run_as_user "cd /home/$USER/mem-apps/xsbench && make module && cp xsbench mosaictest"