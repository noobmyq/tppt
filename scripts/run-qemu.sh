#!/bin/bash

while getopts wldum opt; do
    case $opt in
        w) opt_rw="SET"
        ;;
        l) opt_log="SET" # <-- ADDED
        ;;
        d) opt_debug="SET" # <-- ADDED
        ;;
        u) opt_huge="SET"
	    ;;
        m) opt_manual_qemu="SET"
        ;;
    esac
done

if [[ "$opt_rw" = "SET" ]]; then
    SNAPSHOT=""
else
    SNAPSHOT="-snapshot"
fi
if [[ "$opt_log" = "SET" ]]; then # <-- ADDED
	    SERIAL_OPTIONS="-serial file:qemu_log.txt" # <-- ADDED
fi # <-- ADDED

NCPUS=1
# Conditionally set GDB debug options
if [[ "$opt_debug" = "SET" ]]; then # <-- ADDED
	    DEBUG_OPTIONS="-s -S" # <-- ADDED
	    NCPUS=1
fi # <

if [[ "$opt_huge" = "SET" ]]; then
	HUGE_OPTIONS="transparent_hugepage=never hugepages=0"
else
	HUGE_OPTIONS=""
fi
CONSOLE="console=tty1 highres=off $SERIAL_APPEND"
ROOT="root=/dev/hda rw --no-log"

# check if BASE_DIR is set
: "${BASE_DIR:?BASE_DIR is not set. Please source source.sh first.}"

KERNEL="$BASE_DIR/shadow_pgtbl_kernel/arch/x86_64/boot/bzImage -m 150G"

# if m is set, we use $BASE_DIR/qemu-linux/build/qemu-system-x86_64
if [[ "$opt_manual_qemu" = "SET" ]]; then
    QEMU_BIN="$BASE_DIR/qemu-linux/build/qemu-system-x86_64"
else
    QEMU_BIN="qemu-system-x86_64"
fi

set -x

umount $MNTPNT || true
$QEMU_BIN -cpu host -enable-kvm -smp $NCPUS -hda $DISK -kernel $KERNEL \
	-append "nokaslr $CONSOLE $ROOT $HUGE_OPTIONS " \
	 $SNAPSHOT $DEBUG_OPTIONS -display curses
