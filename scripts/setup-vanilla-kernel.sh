#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# base dir is the parent directory of the script directory
BASE_DIR=$(dirname "$SCRIPT_DIR")

# shadow kernel folder
SHADOW_KERNEL_DIR="$BASE_DIR/shadow_pgtbl_kernel"
LINUX_TP_DIR="$BASE_DIR/linux-tp"

# make sure if the shadow kernel dir exists
if [ ! -d "$SHADOW_KERNEL_DIR" ]; then
    echo "Shadow kernel directory not found: $SHADOW_KERNEL_DIR"
    # need to run setup-linux.sh first, as we need to copy the config file
    echo "Please run setup-linux.sh first."
    exit 1
fi

pushd "$BASE_DIR"

curl -O https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.11.6.tar.xz
tar xf linux-5.11.6.tar.xz
rm linux-5.11.6.tar.xz

# copy the config file from shadow kernel
cp "$SHADOW_KERNEL_DIR/cur_config" linux-5.11.6/.config

# build vanilla kernel
pushd linux-5.11.6
make olddefconfig
# use all available cores up to 30
NUM_CORES=$(nproc)
if [ "$NUM_CORES" -gt 30 ]; then
    NUM_CORES=30
fi
make -j${NUM_CORES}
popd

# build vanilla Linux 6.8 for the new linux-tp/qemu-linux path
if [ ! -d "$LINUX_TP_DIR" ]; then
    echo "linux-tp directory not found: $LINUX_TP_DIR"
    exit 1
fi

curl -O https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.8.tar.xz
tar xf linux-6.8.tar.xz
rm linux-6.8.tar.xz

# copy the config file from the 6.8 TPPT kernel, then let vanilla Kconfig
# drop TPPT-only symbols during olddefconfig
cp "$LINUX_TP_DIR/tppt_config" linux-6.8/.config

pushd linux-6.8
make olddefconfig
make -j${NUM_CORES}
popd
popd
