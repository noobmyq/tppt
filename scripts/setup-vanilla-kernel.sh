#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# base dir is the parent directory of the script directory
BASE_DIR=$(dirname "$SCRIPT_DIR")

# shadow kernel folder
SHADOW_KERNEL_DIR="$BASE_DIR/shadow_pgtbl_kernel"

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
popd

