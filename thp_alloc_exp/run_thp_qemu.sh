#!/bin/bash

set -euo pipefail

EXP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=$(cd "${EXP_DIR}/.." && pwd)

DISK="${DISK:-${BASE_DIR}/disk.img}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
TP_POOL_ENV="${EXP_DIR}/configs/tp_pool.env"

if [[ -f "${TP_POOL_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${TP_POOL_ENV}"
fi

TP_POOL_GB="${TP_POOL_GB:-10}"
TP_POOL_BASE_GB="${TP_POOL_BASE_GB:-10}"

# Backward-compatible knob: if MEM_PER_NODE is set, both nodes inherit it unless overridden.
MEM_PER_NODE="${MEM_PER_NODE:-}"
NODE0_MEM="${NODE0_MEM:-}"
NODE1_MEM="${NODE1_MEM:-}"

if [[ -n "${MEM_PER_NODE}" ]]; then
    NODE0_MEM="${NODE0_MEM:-${MEM_PER_NODE}}"
    NODE1_MEM="${NODE1_MEM:-${MEM_PER_NODE}}"
fi

if [[ -z "${NODE0_MEM}" ]]; then
    NODE0_MEM="${TP_POOL_GB}G"
fi
if [[ -z "${NODE1_MEM}" ]]; then
    NODE1_MEM="${TP_POOL_GB}G"
fi

MODE=""
RW_MODE=0
DEBUG_MODE=0
DISABLE_HUGEPAGE=0

usage() {
    cat <<USAGE
Usage: $0 -k <vanilla|tp|tp_compact> [-w] [-d] [-u]

Options:
  -k mode   Kernel mode to boot
  -w        Writable disk mode (default is -snapshot)
  -d        Start paused with GDB stub (-s -S)
  -u        Append THP-disable cmdline (transparent_hugepage=never hugepages=0)

Environment overrides:
  QEMU_BIN        (default: qemu-system-x86_64)
  DISK            (default: <base>/disk.img)
  MEM_PER_NODE    (legacy: sets both NODE0_MEM/NODE1_MEM)
  NODE0_MEM       (default: \
                   TP_POOL_GB + "G", e.g. 10G)
  NODE1_MEM       (default: TP_POOL_GB + "G", e.g. 10G)
  TP_POOL_GB      (default from configs/tp_pool.env or 10)
  TP_POOL_BASE_GB (default from configs/tp_pool.env or 10)
USAGE
}

parse_gb() {
    local raw="$1"
    local upper
    upper=$(echo "${raw}" | tr '[:lower:]' '[:upper:]')
    if [[ "${upper}" =~ ^([0-9]+)G$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

while getopts ":k:wduh" opt; do
    case "${opt}" in
        k)
            MODE="${OPTARG}"
            ;;
        w)
            RW_MODE=1
            ;;
        d)
            DEBUG_MODE=1
            ;;
        u)
            DISABLE_HUGEPAGE=1
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

if [[ -z "${MODE}" ]]; then
    echo "Mode is required." >&2
    usage
    exit 1
fi

case "${MODE}" in
    vanilla)
        KERNEL="${EXP_DIR}/build/vanilla/arch/x86/boot/bzImage"
        ;;
    tp|tp_compact)
        KERNEL="${EXP_DIR}/build/tp/arch/x86/boot/bzImage"
        ;;
    *)
        echo "Invalid mode: ${MODE}" >&2
        usage
        exit 1
        ;;
esac

if [[ ! -x "${QEMU_BIN}" ]] && ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    echo "QEMU binary not found: ${QEMU_BIN}" >&2
    exit 1
fi

if [[ ! -f "${DISK}" ]]; then
    echo "Disk image not found: ${DISK}" >&2
    exit 1
fi

if [[ ! -f "${KERNEL}" ]]; then
    echo "Kernel image not found: ${KERNEL}" >&2
    echo "Run scripts/setup_thp_experiments.sh first." >&2
    exit 1
fi

if ! NODE0_MEM_GB=$(parse_gb "${NODE0_MEM}"); then
    echo "NODE0_MEM must be an integer in G (e.g. 10G)." >&2
    exit 1
fi
if ! NODE1_MEM_GB=$(parse_gb "${NODE1_MEM}"); then
    echo "NODE1_MEM must be an integer in G (e.g. 10G)." >&2
    exit 1
fi

NODE0_END_GB=${NODE0_MEM_GB}
TOTAL_GB=$((NODE0_MEM_GB + NODE1_MEM_GB))

SNAPSHOT_OPT="-snapshot"
if [[ "${RW_MODE}" -eq 1 ]]; then
    SNAPSHOT_OPT=""
fi

DEBUG_OPTS=""
if [[ "${DEBUG_MODE}" -eq 1 ]]; then
    DEBUG_OPTS="-s -S"
fi

HUGE_OPTS=""
if [[ "${DISABLE_HUGEPAGE}" -eq 1 ]]; then
    HUGE_OPTS="transparent_hugepage=never hugepages=0"
fi

CONSOLE="console=tty1 highres=off"
ROOT="root=/dev/hda rw --no-log"
APPEND="nokaslr ${CONSOLE} ${ROOT} ${HUGE_OPTS}"

POOL_START_GB=${TP_POOL_BASE_GB}
POOL_END_GB=$((TP_POOL_BASE_GB + TP_POOL_GB))
POOL_NODE="unknown"

if (( POOL_END_GB > TOTAL_GB )); then
    echo "TP pool exceeds guest RAM: pool=[${POOL_START_GB},${POOL_END_GB})GB, RAM=[0,${TOTAL_GB})GB" >&2
    exit 1
fi

if (( POOL_START_GB < NODE0_END_GB && POOL_END_GB > NODE0_END_GB )); then
    echo "TP pool crosses NUMA boundary at ${NODE0_END_GB}GB; this breaks isolation." >&2
    echo "Adjust TP_POOL_BASE_GB/TP_POOL_GB or NODE0_MEM/NODE1_MEM." >&2
    exit 1
fi

if (( POOL_END_GB <= NODE0_END_GB )); then
    POOL_NODE=0
else
    POOL_NODE=1
fi

if [[ "${MODE}" == "tp" || "${MODE}" == "tp_compact" ]]; then
    if (( TP_POOL_GB != NODE1_MEM_GB )); then
        echo "Warning: for fair TP-vs-vanilla, a common setup is NODE1_MEM == TP_POOL_GB." >&2
    fi
fi

echo "Launching mode: ${MODE}"
echo "Kernel: ${KERNEL}"
echo "Disk: ${DISK}"
echo "NUMA: node0=${NODE0_MEM}, node1=${NODE1_MEM}"
echo "TP pool: size=${TP_POOL_GB}GB base=${TP_POOL_BASE_GB}GB (from ${TP_POOL_ENV})"
echo "TP pool resides in node${POOL_NODE}"
if [[ "${MODE}" == "tp" || "${MODE}" == "tp_compact" ]]; then
    echo "Recommendation: pin alloctest/tp_frag to node${POOL_NODE} in guest using numactl --cpunodebind=${POOL_NODE} --membind=${POOL_NODE}"
else
    echo "Recommendation: pin alloctest/tp_frag to a single node in guest (commonly node1 for fairness)."
fi

set -x
"${QEMU_BIN}" \
    -cpu host -enable-kvm \
    -smp 1,sockets=1,cores=1,threads=1 \
    -m "${TOTAL_GB}G" \
    -object memory-backend-ram,id=mem0,size="${NODE0_MEM}" \
    -object memory-backend-ram,id=mem1,size="${NODE1_MEM}" \
    -numa node,nodeid=0,cpus=0,memdev=mem0 \
    -numa node,nodeid=1,memdev=mem1 \
    -hda "${DISK}" \
    -kernel "${KERNEL}" \
    -append "${APPEND}" \
    ${SNAPSHOT_OPT} ${DEBUG_OPTS} \
    -display curses 