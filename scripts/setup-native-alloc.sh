#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
NATIVE_DIR="$BASE_DIR/linux-tp-native-alloc"
BENCH_DIR="$BASE_DIR/alloc-bench"
VANILLA_DIR="$BASE_DIR/linux-6.8"
NATIVE_BRANCH=tppt/native-alloc

if [[ ${1:-} == --help ]]; then
    echo "Usage: JOBS=20 $0"
    echo 'Check existing sources, install dependencies, and build QEMU and bare-metal images.'
    echo 'Uses tppt/native-alloc; JOBS defaults to nproc, capped at 30.'
    exit
fi
[[ $# == 0 ]] || { echo 'Use --help for usage' >&2; exit 2; }
JOBS=${JOBS:-$(nproc)}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer' >&2; exit 2; }
if ((JOBS > 30)); then
    JOBS=30
fi

# Source setup belongs to the other setup steps; do not create sibling trees.
if [[ ! -e $NATIVE_DIR/.git || ! -f $NATIVE_DIR/Makefile ]]; then
    echo "Missing native checkout: $NATIVE_DIR" >&2
    echo "Prepare the Linux checkout on branch $NATIVE_BRANCH first." >&2
    exit 1
fi
if [[ ! -x $BENCH_DIR/scripts/build.sh ]]; then
    echo "Missing benchmark builder: $BENCH_DIR/scripts/build.sh" >&2
    echo 'Initialize the alloc-bench repository first.' >&2
    exit 1
fi
if [[ ! -f $VANILLA_DIR/Makefile ]]; then
    echo "Missing vanilla source: $VANILLA_DIR" >&2
    echo 'Prepare linux-6.8 first; see scripts/setup-vanilla-kernel.sh.' >&2
    exit 1
fi

sudo apt-get update
sudo apt-get install -y git xz-utils build-essential bc bison flex \
    libssl-dev libelf-dev pkg-config cpio kmod rsync debhelper dpkg-dev \
    fakeroot python3 busybox-static util-linux qemu-system-x86 ovmf

native_status=$(git -C "$NATIVE_DIR" status --porcelain)
if [[ -n $native_status ]]; then
    echo "Commit or save local changes in $NATIVE_DIR before setup" >&2
    exit 1
fi
git -C "$NATIVE_DIR" checkout "$NATIVE_BRANCH"

# Build the selected branch's committed source, not the builder's default pin.
TP_SOURCE=$(git -C "$NATIVE_DIR" rev-parse HEAD)
for target in qemu baremetal; do
    JOBS="$JOBS" REPO="$NATIVE_DIR" VANILLA_SOURCE="$VANILLA_DIR" TP_SOURCE="$TP_SOURCE" \
        "$BENCH_DIR/scripts/build.sh" "$target"
done

echo "Images built in $BENCH_DIR/images/{qemu,baremetal}/"
