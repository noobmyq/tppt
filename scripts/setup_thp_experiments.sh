#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

EXP_DIR="${BASE_DIR}/thp_alloc_exp"
SRC_DIR="${EXP_DIR}/src"
BUILD_DIR="${EXP_DIR}/build"
CONFIG_DIR="${EXP_DIR}/configs"

TP_UPSTREAM_SRC="${BASE_DIR}/shadow_pgtbl_kernel"
VANILLA_UPSTREAM_SRC="${BASE_DIR}/linux-5.11.6"
TP_EXP_SRC="${SRC_DIR}/tp"
VANILLA_EXP_SRC="${SRC_DIR}/vanilla"

# Fixed experiment pool configuration: 10GB pool starting at 10GB.
TP_POOL_GB=10
TP_POOL_BASE_GB=10

BASE_CONFIG="${TP_UPSTREAM_SRC}/cur_config"
if [[ ! -f "${BASE_CONFIG}" ]]; then
    BASE_CONFIG="${TP_UPSTREAM_SRC}/.config"
fi

JOBS=$(nproc)
if [[ "${JOBS}" -gt 30 ]]; then
    JOBS=30
fi

usage() {
    cat <<USAGE
Usage: $0 [-j jobs]

Always performs a fresh setup:
  1) Recursively copies TP and vanilla source trees into thp_alloc_exp/src
  2) Forces TP pool config to 10GB size, 10GB base in copied TP source
  3) Regenerates configs in thp_alloc_exp/configs
  4) Rebuilds TP and vanilla kernels in thp_alloc_exp/build
USAGE
}

while getopts ":j:h" opt; do
    case "${opt}" in
        j)
            JOBS="${OPTARG}"
            ;;
        h)
            usage
            exit 0
            ;;
        :)
            echo "Missing argument for -${OPTARG}" >&2
            usage
            exit 1
            ;;
        ?)
            echo "Unknown option: -${OPTARG}" >&2
            usage
            exit 1
            ;;
    esac
done

require_path() {
    local p="$1"
    if [[ ! -e "${p}" ]]; then
        echo "Required path not found: ${p}" >&2
        exit 1
    fi
}

copy_tree_clean() {
    local src="$1"
    local dst="$2"

    rm -rf "${dst}"
    mkdir -p "${dst}"

    # Real copy (no symlinks), preserving metadata.
    cp -a "${src}/." "${dst}/"

    # Ensure copied source is clean for O= builds.
    rm -f "${dst}/.config" "${dst}/Module.symvers"
    rm -rf "${dst}/include/config" \
           "${dst}/include/generated" \
           "${dst}/arch/x86/include/generated"
}

patch_tp_pool_header() {
    local hdr="${TP_EXP_SRC}/include/linux/tp-mosaic.h"
    local base_bytes=$((TP_POOL_BASE_GB * 1024 * 1024 * 1024))

    if [[ ! -f "${hdr}" ]]; then
        echo "TP header not found: ${hdr}" >&2
        exit 1
    fi

    sed -i -E "s|^#define RESERVED_GB .*|#define RESERVED_GB ${TP_POOL_GB}ULL|" "${hdr}"
    sed -i -E "s|^#define RESERVED_BASE .*|#define RESERVED_BASE ${base_bytes}ull // ${TP_POOL_BASE_GB}GB|" "${hdr}"
}

prepare_config() {
    local src="$1"
    local out_cfg="$2"

    cp "${BASE_CONFIG}" "${out_cfg}"

    if [[ ! -x "${src}/scripts/config" ]]; then
        make -C "${src}" scripts >/dev/null
    fi

    "${src}/scripts/config" --file "${out_cfg}" \
        -e CONFIG_NUMA \
        -e CONFIG_X86_64_ACPI_NUMA \
        -e CONFIG_ACPI_NUMA \
        -d CONFIG_NUMA_BALANCING
}

build_kernel() {
    local name="$1"
    local src="$2"
    local out="$3"
    local cfg="$4"

    rm -rf "${out}"
    mkdir -p "${out}"
    cp "${cfg}" "${out}/.config"

    make -C "${src}" O="${out}" KCONFIG_CONFIG="${out}/.config" olddefconfig
    make -C "${src}" O="${out}" KCONFIG_CONFIG="${out}/.config" -j"${JOBS}" vmlinux bzImage

    make -C "${src}" O="${out}" KCONFIG_CONFIG="${out}/.config" scripts_gdb

    if [[ ! -f "${out}/vmlinux-gdb.py" ]]; then
        ln -fs "${src}/scripts/gdb/vmlinux-gdb.py" "${out}/vmlinux-gdb.py"
    fi

    if [[ ! -f "${out}/arch/x86/boot/bzImage" ]]; then
        echo "Build finished but bzImage missing for ${name}" >&2
        exit 1
    fi
}

require_path "${TP_UPSTREAM_SRC}"
require_path "${VANILLA_UPSTREAM_SRC}"
require_path "${BASE_CONFIG}"

mkdir -p "${EXP_DIR}" "${SRC_DIR}" "${BUILD_DIR}" "${CONFIG_DIR}"

echo "Preparing fresh source copies..."
copy_tree_clean "${TP_UPSTREAM_SRC}" "${TP_EXP_SRC}"
copy_tree_clean "${VANILLA_UPSTREAM_SRC}" "${VANILLA_EXP_SRC}"
patch_tp_pool_header

TP_CFG="${CONFIG_DIR}/tp.config"
VANILLA_CFG="${CONFIG_DIR}/vanilla.config"
TP_POOL_ENV="${CONFIG_DIR}/tp_pool.env"

prepare_config "${TP_EXP_SRC}" "${TP_CFG}"
prepare_config "${VANILLA_EXP_SRC}" "${VANILLA_CFG}"

cat > "${TP_POOL_ENV}" <<POOLENV
TP_POOL_GB=${TP_POOL_GB}
TP_POOL_BASE_GB=${TP_POOL_BASE_GB}
POOLENV

echo "Prepared source layout under ${SRC_DIR} (real copies, no symlinks)."
echo "Prepared configs under ${CONFIG_DIR}."
echo "TP pool in experiment TP source: size=${TP_POOL_GB}GB base=${TP_POOL_BASE_GB}GB"

echo "Building TP kernel..."
build_kernel "tp" "${TP_EXP_SRC}" "${BUILD_DIR}/tp" "${TP_CFG}"

echo "Building vanilla kernel..."
build_kernel "vanilla" "${VANILLA_EXP_SRC}" "${BUILD_DIR}/vanilla" "${VANILLA_CFG}"

echo "Build complete:"
echo "  TP kernel:      ${BUILD_DIR}/tp/arch/x86/boot/bzImage"
echo "  Vanilla kernel: ${BUILD_DIR}/vanilla/arch/x86/boot/bzImage"
