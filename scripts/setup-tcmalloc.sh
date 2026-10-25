#!/bin/bash
# Run as root inside the Ubuntu Focal amd64 guest/chroot.
# Builds Google TCMalloc in /opt; workload linking is a separate step.
set -Eeuo pipefail
trap 'echo "TCMalloc setup failed at line $LINENO" >&2' ERR

if (( EUID != 0 )); then
    echo "Run this installer as root inside the guest/chroot." >&2
    exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_CODENAME:-} != focal ]] || \
    [[ $(dpkg --print-architecture) != amd64 ]]; then
    echo "This installer requires Ubuntu Focal amd64." >&2
    exit 1
fi

# Pin the source/tool versions used by the successful manual build.
TCMALLOC_COMMIT=b5de23b66f743431aa906ba783af4afa9cf507f5
BAZEL_VERSION=8.4.2
BAZELISK_VERSION=1.29.0
INSTALL_DIR=/opt/tppt-tcmalloc
SOURCE_DIR=$INSTALL_DIR/tcmalloc

tmp_dir=$(mktemp -d /tmp/tppt-tcmalloc.XXXXXX)
mounted_proc=0
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$tmp_dir"
    if (( mounted_proc )); then
        if ! umount /proc; then
            echo "Could not unmount the /proc mounted by this installer." >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

# Bazel needs /proc/self/exe. Leave an existing proc mount in place; remove
# only a mount created by this invocation, including on build failure.
mkdir -p /proc
if ! mountpoint -q /proc; then
    mount -t proc proc /proc
    mounted_proc=1
fi
readlink /proc/self/exe

export DEBIAN_FRONTEND=noninteractive
# Focal's libobjc-9-dev (required by clang-22) lives in universe.
printf '%s\n' 'deb http://archive.ubuntu.com/ubuntu focal universe' \
    > /etc/apt/sources.list.d/tppt-universe.list
apt-get update
apt-get install -y ca-certificates curl gnupg git build-essential python3 unzip

curl -fL https://apt.llvm.org/llvm-snapshot.gpg.key -o "$tmp_dir/llvm.asc"
install -d -m 755 /usr/share/keyrings
gpg --batch --yes --dearmor -o /usr/share/keyrings/tppt-llvm.gpg "$tmp_dir/llvm.asc"
chmod 644 /usr/share/keyrings/tppt-llvm.gpg
printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/tppt-llvm.gpg] https://apt.llvm.org/focal/ llvm-toolchain-focal-22 main' \
    > /etc/apt/sources.list.d/tppt-llvm.list
apt-get update
apt-get install -y clang-22

curl -fL \
    "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-amd64" \
    -o "$tmp_dir/bazel"
install -D -m 755 "$tmp_dir/bazel" /usr/local/bin/bazel

mkdir -p "$INSTALL_DIR"
if [[ ! -d $SOURCE_DIR ]]; then
    git init "$SOURCE_DIR"
    git -C "$SOURCE_DIR" remote add origin https://github.com/google/tcmalloc.git
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$TCMALLOC_COMMIT"
    git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
fi
cd "$SOURCE_DIR"
if [[ $(git rev-parse HEAD) != "$TCMALLOC_COMMIT" ]]; then
    echo "TCMalloc checkout differs from the pinned commit: $TCMALLOC_COMMIT" >&2
    exit 1
fi
git rev-parse HEAD > "$INSTALL_DIR/TCMALLOC_COMMIT"
printf '%s\n' "$BAZEL_VERSION" > .bazelversion

# Resolve the Abseil compatibility-level conflict seen with these modules.
# Reuse the override already applied during manual installation.
if ! grep -q 'module_name = "abseil-cpp"' MODULE.bazel; then
    cat >> MODULE.bazel <<'EOF'

single_version_override(
    module_name = "abseil-cpp",
    version = "20260526.0",
)
EOF
fi

# Keep these two known diagnostics visible as warnings; all other compiler
# errors still fail the build. The lock-annotation warning is not validated
# as harmless by the smoke test.
/usr/local/bin/bazel --batch --ignore_all_rc_files build \
    --jobs=4 \
    --compilation_mode=opt \
    --cxxopt=-std=c++17 \
    --cxxopt=-Wno-error=c++20-extensions \
    --cxxopt=-Wno-error=thread-safety-precise \
    --repo_env=CC=/usr/bin/clang-22 \
    --repo_env=CXX=/usr/bin/clang++-22 \
    //tcmalloc:tcmalloc \
    //tcmalloc/testing:hello_main

# Require the example to execute and report TCMalloc accounting for both
# 1 GiB allocations; hello_main itself does not assert its malloc succeeded.
./bazel-bin/tcmalloc/testing/hello_main | tee "$INSTALL_DIR/hello_main.log"
awk '/Current heap size =/ && $5 >= 2147483648 { ok = 1 }
     END { exit !ok }' "$INSTALL_DIR/hello_main.log"

if (( mounted_proc )); then
    umount /proc
    mounted_proc=0
fi
echo "TCMalloc build and smoke test succeeded in $SOURCE_DIR"
