#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# base dir is the parent directory of the script directory
BASE_DIR=$(dirname "$SCRIPT_DIR")

# shadow kernel folder
LINUX_TP_DIR="$BASE_DIR/linux-tp"

pushd "$BASE_DIR"

# # use all available cores up to 30
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
