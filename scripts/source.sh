
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
export BASE_DIR=$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)

export DISK="$BASE_DIR/disk.img"
export SIZE="100G"
export MNTPNT="$BASE_DIR/mount.point"
export OS="focal"
export ARCH="amd64"
export KERNEL=`uname -r`
export USER=$USER

alias ch='sudo -i chroot $MNTPNT'
alias m='sudo mount -o loop $DISK $MNTPNT'
alias um='sudo umount $MNTPNT'
alias r='sg kvm -c "$SCRIPT_DIR/run-qemu.sh -w"'
alias ru='sg kvm -c "$SCRIPT_DIR/run-qemu.sh -w -u"'
alias rud='sg kvm -c "$SCRIPT_DIR/run-qemu.sh -w -u -d"'
alias rum='sg kvm -c "$SCRIPT_DIR/run-qemu.sh -w -u -m"'