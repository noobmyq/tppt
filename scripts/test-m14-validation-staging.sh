#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
STAGER=$SCRIPT_DIR/stage-m14-validation.sh
temporary=$(mktemp -d /tmp/tppt-m14-staging-test.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT

"$STAGER" --check
TPPT_M14_PREFLIGHT_ONLY=1 DISK="$temporary/not-created.img" SIZE=1G \
	MNTPNT="$temporary/not-mounted" USER=tppttest \
	"$SCRIPT_DIR/setup-disk.sh"
test ! -e "$temporary/not-created.img"
mkdir -p "$temporary/root/home/tppttest"
"$STAGER" --root "$temporary/root" --user tppttest

destination=$temporary/root/home/tppttest/tppt-m14
cmp "$BASE_DIR/linux-tp/tools/testing/tppt/tppt_shared_probe.c" \
	"$destination/linux/tools/testing/tppt/tppt_shared_probe.c"
cmp "$BASE_DIR/linux-tp/include/linux/tppt_shmem_probe.h" \
	"$destination/linux/include/linux/tppt_shmem_probe.h"
cmp "$BASE_DIR/workloads/m14-validation/postgres/prepare.sh" \
	"$destination/postgres/prepare.sh"
grep -qx 'linux=70d6878cabe77425814aca1a74614419421f1ea5' \
	"$destination/repositories.txt"
grep -qx 'qemu=1629b56c6d3e2b4f757563acd01ee4eba4714255' \
	"$destination/repositories.txt"
grep -qx 'workloads=565f976b00e21c6a2486f34104f8e92c3638fc03' \
	"$destination/repositories.txt"

make -C "$destination/linux/tools/testing/tppt" clean all
test -x "$destination/linux/tools/testing/tppt/tppt_shared_probe"
mkdir "$temporary/microbenchmark"
cp "$BASE_DIR/workloads/microbenchmark/Makefile" \
	"$BASE_DIR/workloads/microbenchmark/tppt_huge_shared.c" \
	"$temporary/microbenchmark/"
make -C "$temporary/microbenchmark" clean unit_tppt_huge_shared
test -x "$temporary/microbenchmark/unit_tppt_huge_shared"

if "$STAGER" --root "$temporary/root" --user tppttest 2>/dev/null; then
	echo "stager overwrote an existing destination" >&2
	exit 1
fi
if "$STAGER" --root "$temporary/root" --user '../bad' 2>/dev/null; then
	echo "stager accepted an invalid guest user" >&2
	exit 1
fi

printf 'M14 validation staging tests passed\n'
