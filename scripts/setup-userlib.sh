#!/bin/bash

set -euo pipefail

function chroot_run {
	sudo chroot $MNTPNT "$@"
}

# redis libs
REDIS_LIBS=(
    libreadline-dev
)

# postgres libs
POSTGRES_LIBS=(
    zlib1g-dev
)


chroot_run apt-get update
# go into /home/$USER/apps/redis and build
chroot_run bash -c "cd /home/$USER/apps/redis && make && make bench_redis_st"