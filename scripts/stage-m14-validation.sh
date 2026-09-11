#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
LINUX_DIR=$BASE_DIR/linux-tp
QEMU_DIR=$BASE_DIR/qemu-linux
WORKLOADS_DIR=$BASE_DIR/workloads

LINUX_COMMIT=70d6878cabe77425814aca1a74614419421f1ea5
QEMU_COMMIT=1629b56c6d3e2b4f757563acd01ee4eba4714255
WORKLOADS_COMMIT=565f976b00e21c6a2486f34104f8e92c3638fc03

fail()
{
	printf 'stage-m14-validation.sh: %s\n' "$*" >&2
	exit 1
}

require_commit()
{
	local repository=$1
	local expected=$2
	local name=$3
	local actual

	actual=$(git -C "$repository" rev-parse HEAD 2>/dev/null) ||
		fail "cannot resolve $name repository commit: $repository"
	[[ $actual == "$expected" ]] ||
		fail "$name commit is $actual, expected reviewed $expected"
}

require_clean_paths()
{
	local repository=$1
	shift

	git -C "$repository" diff --quiet HEAD -- "$@" ||
		fail "reviewed source differs from its committed state: $repository"
	for path in "$@"; do
		[[ -f $repository/$path ]] || fail "missing reviewed source: $repository/$path"
	done
}

check_sources()
{
	require_commit "$LINUX_DIR" "$LINUX_COMMIT" linux-tp
	require_commit "$QEMU_DIR" "$QEMU_COMMIT" qemu-linux
	require_commit "$WORKLOADS_DIR" "$WORKLOADS_COMMIT" workloads
	require_clean_paths "$LINUX_DIR" \
		tools/testing/tppt/Makefile \
		tools/testing/tppt/tppt_shared_probe.c \
		include/linux/tppt_shmem_probe.h
	require_clean_paths "$QEMU_DIR" \
		run_tppt_huge_shared.sh \
		run_tppt_postgres_huge.sh \
		scripts/tppt/shared.py \
		scripts/tppt/shared_driver.py \
		scripts/tppt/postgres.py \
		scripts/tppt/postgres_driver.py
	require_clean_paths "$WORKLOADS_DIR" \
		microbenchmark/Makefile \
		microbenchmark/tppt_huge_shared.c \
		microbenchmark/tppt_huge_shared.md \
		m14-validation/postgres/README.md \
		m14-validation/postgres/prepare.sh \
		m14-validation/postgres/test_prepare.sh \
		m14-validation/postgres/tppt-m14-postgres.patch
}

root=
user=
check_only=0
while (($#)); do
	case $1 in
	--check)
		check_only=1
		shift
		;;
	--root)
		(($# >= 2)) || fail "--root requires a directory"
		root=$2
		shift 2
		;;
	--user)
		(($# >= 2)) || fail "--user requires a name"
		user=$2
		shift 2
		;;
	*) fail "unknown argument: $1" ;;
	esac
done

check_sources
if ((check_only)); then
	[[ -z $root && -z $user ]] || fail "--check does not accept staging options"
	printf 'M14 validation source check passed\n'
	exit 0
fi

[[ -n $root && -n $user ]] || fail "--root and --user are required"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "invalid guest user: $user"
root=$(realpath "$root")
[[ $root != / ]] || fail "refusing to stage into the host root"
[[ -d $root/home/$user ]] || fail "guest home is missing: $root/home/$user"

destination=$root/home/$user/tppt-m14
[[ ! -e $destination ]] || fail "staging destination already exists: $destination"
install -d "$destination/linux/tools/testing/tppt"
install -d "$destination/linux/include/linux"
install -d "$destination/postgres"
install -m 0644 "$LINUX_DIR/tools/testing/tppt/Makefile" \
	"$destination/linux/tools/testing/tppt/Makefile"
install -m 0644 "$LINUX_DIR/tools/testing/tppt/tppt_shared_probe.c" \
	"$destination/linux/tools/testing/tppt/tppt_shared_probe.c"
install -m 0644 "$LINUX_DIR/include/linux/tppt_shmem_probe.h" \
	"$destination/linux/include/linux/tppt_shmem_probe.h"
cp -a "$WORKLOADS_DIR/m14-validation/postgres/." "$destination/postgres/"

cat >"$destination/repositories.txt" <<EOF
linux=$LINUX_COMMIT
qemu=$QEMU_COMMIT
workloads=$WORKLOADS_COMMIT
EOF

cmp "$LINUX_DIR/tools/testing/tppt/tppt_shared_probe.c" \
	"$destination/linux/tools/testing/tppt/tppt_shared_probe.c"
cmp "$LINUX_DIR/include/linux/tppt_shmem_probe.h" \
	"$destination/linux/include/linux/tppt_shmem_probe.h"
cmp "$WORKLOADS_DIR/m14-validation/postgres/tppt-m14-postgres.patch" \
	"$destination/postgres/tppt-m14-postgres.patch"
printf 'Staged reviewed M14 validation sources at %s\n' "$destination"
