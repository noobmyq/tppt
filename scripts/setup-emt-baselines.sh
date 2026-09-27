#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TPPT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SRC_ROOT="${TPPT_ROOT}/emt-baselines/src"
readonly BUILD_ROOT="${TPPT_ROOT}/emt-baselines/build"
readonly JOBS=20

# Pinned from the branches used by xlab-uiuc/emt at wrapper revision
# e4d2e65ca39143cb57bf862af50f56ff0f07d53e.
readonly EMT_LINUX_URL="https://github.com/xlab-uiuc/emt-linux.git"
readonly EMT_LINUX_MAIN_COMMIT="a450da1de9c151dee2b4c995a29fe7c6277aab8b"
readonly EMT_LINUX_FPT_COMMIT="61d3e2553d43f3befca503f92d338a8c0a9379ca"
readonly QEMU_EMT_URL="https://github.com/xlab-uiuc/qemu-emt.git"
readonly QEMU_EMT_COMMIT="a417c4ea5cf87a9cce3a95a9e0ddd8feafb4435a"

active_qemu_source=""
active_qemu_build_link=""

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

restore_qemu_target()
{
    if [[ -n "${active_qemu_source}" ]]; then
        git -C "${active_qemu_source}" restore -- \
            configs/targets/x86_64-softmmu.mak >/dev/null 2>&1 || true
        active_qemu_source=""
    fi
}

cleanup_qemu_build_link()
{
    if [[ -n "${active_qemu_build_link}" ]]; then
        unlink -- "${active_qemu_build_link}" >/dev/null 2>&1 || true
        active_qemu_build_link=""
    fi
}

trap 'restore_qemu_target; cleanup_qemu_build_link' EXIT

checkout_source()
{
    local name="$1"
    local url="$2"
    local branch="$3"
    local commit="$4"
    local destination="${SRC_ROOT}/${name}"

    if [[ ! -e "${destination}" ]]; then
        printf 'Cloning %s...\n' "${name}"
        git clone --filter=blob:none --depth=1 --single-branch \
            --branch "${branch}" -- "${url}" "${destination}"
    elif [[ ! -d "${destination}/.git" ]]; then
        die "${destination} exists but is not a Git checkout"
    fi

    [[ "$(git -C "${destination}" remote get-url origin)" == "${url}" ]] || \
        die "${destination} has an unexpected origin"
    [[ -z "$(git -C "${destination}" status --porcelain --untracked-files=all)" ]] || \
        die "${destination} is dirty"

    if ! git -C "${destination}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        git -C "${destination}" fetch --depth=1 origin "${commit}"
    fi

    if [[ "$(git -C "${destination}" rev-parse HEAD)" != "${commit}" ]] || \
        git -C "${destination}" symbolic-ref --quiet HEAD >/dev/null; then
        git -C "${destination}" checkout --detach "${commit}"
    fi
}

build_linux()
{
    local name="$1"
    local config="$2"
    local localversion="$3"
    local source_dir="${SRC_ROOT}/${name}"
    local build_dir="${BUILD_ROOT}/${name}"

    printf 'Building %s...\n' "${name}"
    mkdir -p -- "${build_dir}"
    cp -- "${source_dir}/${config}" "${build_dir}/.config"
    make -C "${source_dir}" O="${build_dir}" olddefconfig
    make -C "${source_dir}" O="${build_dir}" -j"${JOBS}" \
        LOCALVERSION="${localversion}"
}

build_qemu()
{
    local name="$1"
    local profile_config="$2"
    local warning_cflags="$3"
    local source_dir="${SRC_ROOT}/${name}"
    local build_dir="${BUILD_ROOT}/${name}"
    local build_link="${source_dir}/build"
    local target_config="configs/targets/x86_64-softmmu.mak"
    local status

    printf 'Building %s...\n' "${name}"
    mkdir -p -- "${build_dir}"
    if [[ -f "${build_dir}/config.status" ]]; then
        make -C "${build_dir}" distclean
    fi
    [[ ! -e "${build_link}" && ! -L "${build_link}" ]] || \
        die "${build_link} already exists"
    git -C "${source_dir}" diff --quiet -- "${target_config}" || \
        die "${source_dir}/${target_config} has local changes"

    ln -s -- "${build_dir}" "${build_link}"
    active_qemu_build_link="${build_link}"
    active_qemu_source="${source_dir}"
    cp -- "${source_dir}/${profile_config}" "${source_dir}/${target_config}"

    set +e
    (
        cd -- "${build_dir}"
        if [[ -n "${warning_cflags}" ]]; then
            CFLAGS="${warning_cflags}" "${source_dir}/configure" \
                --target-list=x86_64-softmmu --enable-plugins --enable-debug \
                --disable-linux-io-uring
        else
            "${source_dir}/configure" --target-list=x86_64-softmmu \
                --enable-plugins --enable-debug --disable-linux-io-uring
        fi
    )
    status=$?
    set -e

    (( status == 0 )) || die "QEMU configure failed for ${name}"
    make -C "${build_dir}" -j"${JOBS}"
    restore_qemu_target
    cleanup_qemu_build_link
}

(( $# == 0 )) || die "this script does not accept arguments"
command -v git >/dev/null 2>&1 || die "git is required"
command -v make >/dev/null 2>&1 || die "make is required"
mkdir -p -- "${SRC_ROOT}" "${BUILD_ROOT}"

checkout_source linux-radix "${EMT_LINUX_URL}" main "${EMT_LINUX_MAIN_COMMIT}"
checkout_source linux-ecpt "${EMT_LINUX_URL}" main "${EMT_LINUX_MAIN_COMMIT}"
checkout_source linux-fpt "${EMT_LINUX_URL}" FPT "${EMT_LINUX_FPT_COMMIT}"
checkout_source qemu-radix "${QEMU_EMT_URL}" execlog_addr_dump "${QEMU_EMT_COMMIT}"
checkout_source qemu-ecpt "${QEMU_EMT_URL}" execlog_addr_dump "${QEMU_EMT_COMMIT}"
checkout_source qemu-fpt "${QEMU_EMT_URL}" execlog_addr_dump "${QEMU_EMT_COMMIT}"

build_linux linux-radix configs/general_interface_radix_config -gen-x86
build_linux linux-ecpt configs/general_interface_ECPT_config -gen-ECPT
build_linux linux-fpt configs/general_interface_FPT_config -gen-FPT-L4L3L2L1

build_qemu qemu-radix configs/targets/x86_64_radix-softmmu.mak \
    -Wno-unused-function
build_qemu qemu-ecpt configs/targets/x86_64_ecpt-softmmu.mak \
    -Wno-unused-function
build_qemu qemu-fpt x86_64-fpt-softmmu.mak ""

printf 'EMT radix, ECPT, and FPT builds are ready under %s\n' "${BUILD_ROOT}"
