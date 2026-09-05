#!/bin/bash

set -euo pipefail

OS="focal"
ARCH="amd64"

# check if envvar exists: DISK, SIZE, MNTPNT, OS, ARCH
: "${DISK:?DISK not set}"
: "${SIZE:?SIZE not set}"
: "${MNTPNT:?MNTPNT not set}"
: "${USER:?USER not set}"

# use current user
PASS=$USER
TTYS=ttyS0

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
APP_DIR=$SCRIPT_DIR/../workloads/qemu-dynamorio-workload/linux-workload
MEM_APP_DIR=$SCRIPT_DIR/../workloads/qemu-dynamorio-workload/osv-workload
MICROBENCH_DIR=$SCRIPT_DIR/../workloads/microbenchmark
# change directory to parent directory
cd "$SCRIPT_DIR/.."

for source in Makefile fork_overhead.c tppt_huge_fork.c; do
	if [[ ! -f "$MICROBENCH_DIR/$source" ]]; then
		echo "missing required microbenchmark source: $MICROBENCH_DIR/$source" >&2
		exit 1
	fi
done

qemu-img create $DISK $SIZE

mkfs.ext4 -F $DISK

sudo mkdir -p $MNTPNT
sudo mount -o loop $DISK $MNTPNT

sudo debootstrap --arch $ARCH $OS $MNTPNT

sudo mkdir -p $MNTPNT/dev
sudo mount --bind /dev/ $MNTPNT/dev
    
function chroot_run {
	sudo chroot $MNTPNT "$@"
}

chroot_run rm -f /etc/init/tty[2345678].conf
chroot_run sed -i "s:/dev/tty\\[1-[2-8]\\]:/dev/tty1:g" /etc/default/console-setup

chroot_run adduser $USER --disabled-password --gecos ""
# Set password to be the same as the username
echo "$USER:$USER" | sudo chroot $MNTPNT chpasswd

chroot_run sed -i "s/^ExecStart.*$/ExecStart=-\/sbin\/agetty --noissue --autologin $USER %I $TERM/g" /lib/systemd/system/getty@.service
chroot_run sed -i "/User privilege specification/a $USER\tALL=(ALL) NOPASSWD:ALL" /etc/sudoers


# make sure /home/$USER/apps exists
chroot_run mkdir -p /home/$USER/apps
sudo cp -r $APP_DIR/* $MNTPNT/home/$USER/apps
chroot_run chown -R $USER:$USER /home/$USER/

# make sure /home/$USER/microbenchmark exists
chroot_run mkdir -p /home/$USER/microbenchmark
sudo cp -r $MICROBENCH_DIR/* $MNTPNT/home/$USER/microbenchmark
sudo rm -f $MNTPNT/home/$USER/microbenchmark/unit_*
chroot_run chown -R $USER:$USER /home/$USER/microbenchmark

# # make sure /home/$USER/mem-apps exists
chroot_run mkdir -p /home/$USER/mem-apps
sudo cp -r $MEM_APP_DIR/* $MNTPNT/home/$USER/mem-apps
chroot_run chown -R $USER:$USER /home/$USER/mem-apps

# copy scripts
sudo cp $SCRIPT_DIR/pte_control_conf/vmfiles/pte_stats_monitor.sh $MNTPNT/home/$USER/
chroot_run chown $USER:$USER /home/$USER/pte_stats_monitor.sh

# inside mem-apps we need to build those apps as user $USER
# TODO: build the apps inside the chroot as $USER

chroot_run apt-get update
chroot_run apt-get install --yes sysstat psmisc
chroot_run apt-get install --yes libgomp1
chroot_run apt-get install --yes screen
chroot_run apt-get install --yes build-essential autoconf
chroot_run apt-get install --yes initramfs-tools
chroot_run apt-get install --yes time
chroot_run apt-get install --yes vim 

sudo tee $MNTPNT/tmp/tppt_exec.c >/dev/null <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef __NR_tppt_execveat
#define __NR_tppt_execveat 462
#endif

#define TPPT_EXEC_ENABLE (1ULL << 0)
#define TPPT_EXEC_STRICT (1ULL << 1)

extern char **environ;

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: tppt_exec <program> [args...]\n");
        return 2;
    }

    syscall(__NR_tppt_execveat, AT_FDCWD, argv[1], &argv[1], environ, 0,
            TPPT_EXEC_ENABLE | TPPT_EXEC_STRICT);

    perror("tppt_execveat");
    return errno ? errno : 1;
}
EOF

chroot_run gcc -O2 -Wall -static /tmp/tppt_exec.c -o /usr/local/bin/tppt_exec
chroot_run chmod 755 /usr/local/bin/tppt_exec
chroot_run rm -f /tmp/tppt_exec.c


sudo umount $MNTPNT/dev;
sudo umount $MNTPNT;
