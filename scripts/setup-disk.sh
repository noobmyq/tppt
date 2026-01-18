#!/bin/bash

set -euo pipefail

# check if envvar exists: DISK, SIZE, MNTPNT, OS, ARCH
: "${DISK:?DISK not set}"
: "${SIZE:?SIZE not set}"
: "${MNTPNT:?MNTPNT not set}"
: "${OS:?OS not set}"
: "${ARCH:?ARCH not set}"

# use current user
PASS=$USER
TTYS=ttyS0

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
APP_DIR=$SCRIPT_DIR/../workloads/qemu-dynamorio-workload/linux-workload

# change directory to parent directory
cd "$SCRIPT_DIR/.."

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

chroot_run sed -i "s/^ExecStart.*$/ExecStart=-\/sbin\/agetty --noissue --autologin $USER %I $TERM/g" /lib/systemd/system/getty@.service
chroot_run sed -i "/User privilege specification/a $USER\tALL=(ALL) NOPASSWD:ALL" /etc/sudoers


# make sure /home/$USER/apps exists
chroot_run mkdir -p /home/$USER/apps
sudo cp -r $APP_DIR/* $MNTPNT/home/$USER/apps
chroot_run chown -R $USER:$USER /home/$USER/

chroot_run apt-get update
chroot_run apt-get install --yes sysstat psmisc
chroot_run apt-get install --yes libgomp1
chroot_run apt-get install --yes screen
chroot_run apt-get install --yes build-essential autoconf
chroot_run apt-get install --yes initramfs-tools
chroot_run apt-get install --yes time
chroot_run apt-get install --yes vim 


sudo umount $MNTPNT/dev;
sudo umount $MNTPNT;