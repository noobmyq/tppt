#!/bin/bash
# Run as root inside the existing guest/chroot; LLVM/Bazel must be installed.
# Build selected THP workloads with original 2 MiB and patched 8 MiB TCMalloc.
set -Eeuo pipefail
trap 'echo "THP TCMalloc build failed at line $LINENO" >&2' ERR

if (( EUID != 0 )); then
    echo "Run this builder as root inside the guest/chroot." >&2
    exit 1
fi
if (( $# < 1 )) || [[ ! $1 =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    echo "usage: $0 <workload-user> [xsbench gups btree dc pr bfs dfs sssp tc cc]" >&2
    exit 2
fi
WORKLOAD_USER=$1
shift
workloads=("$@")
if (( ${#workloads[@]} == 0 )); then
    workloads=(xsbench gups btree dc pr bfs dfs sssp tc cc)
fi
declare -A selected=()
graph_selected=0
for name in "${workloads[@]}"; do
    case "$name" in
        xsbench|gups|btree) ;;
        dc|pr|bfs|dfs|sssp|tc|cc) graph_selected=1 ;;
        *) echo "Unknown workload: $name" >&2; exit 2 ;;
    esac
    if [[ -n ${selected[$name]:-} ]]; then
        echo "Duplicate workload: $name" >&2
        exit 2
    fi
    selected[$name]=1
done

INSTALL_DIR=${TPPT_TCMALLOC_DIR:-/opt/tppt-tcmalloc}
SOURCE_DIR=$INSTALL_DIR/tcmalloc
MEM_APP_DIR=${TPPT_MEM_APPS_DIR:-/home/$WORKLOAD_USER/mem-apps}
GRAPHBIG_DIR=${TPPT_GRAPHBIG_DIR:-$MEM_APP_DIR/graphbig}
BUILD_DIR=$INSTALL_DIR/thp-build
TCMALLOC_COMMIT=b5de23b66f743431aa906ba783af4afa9cf507f5
export USE_BAZEL_VERSION=8.4.2
for tool in git tar gcc g++ make python3 nm readelf /usr/local/bin/bazel /usr/bin/clang-22 /usr/bin/clang++-22; do
    command -v "$tool" >/dev/null
done
if [[ $(git -C "$SOURCE_DIR" rev-parse HEAD) != "$TCMALLOC_COMMIT" ]]; then
    echo "Expected TCMalloc commit $TCMALLOC_COMMIT" >&2
    exit 1
fi

tmp_dir=$(mktemp -d /tmp/tppt-thp-build.XXXXXX)
mounted_proc=0
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$tmp_dir"
    if (( mounted_proc )); then
        if ! umount /proc; then
            echo "Could not unmount the /proc mounted by this builder." >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p /proc
if ! mountpoint -q /proc; then
    mount -t proc proc /proc
    mounted_proc=1
fi

# Read committed sources, not the locally patched checkout. Neither variant
# changes the user's /opt/tppt-tcmalloc/tcmalloc tree.
git -C "$SOURCE_DIR" archive "$TCMALLOC_COMMIT" > "$tmp_dir/tcmalloc.tar"
for variant in 2m 8m; do
    mkdir "$tmp_dir/tcmalloc-$variant"
    tar -xf "$tmp_dir/tcmalloc.tar" -C "$tmp_dir/tcmalloc-$variant"
done

python3 - "$tmp_dir/tcmalloc-8m" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def patch(name, old, new):
    p = root / name
    s = p.read_text()
    if s.count(old) != 1:
        raise SystemExit(f"Unexpected committed source: {name}; stopped")
    p.write_text(s.replace(old, new, 1))

patch("tcmalloc/internal/config.h", '''#if defined(__x86_64__)
// x86 has 2 MiB huge pages
static constexpr size_t kHugePageShift = 21;''',
'''#if defined(__x86_64__)
// TPPT experiment: 8 MiB allocator huge-page granularity.
static constexpr size_t kHugePageShift = 23;''')
patch("tcmalloc/huge_page_tracker.h", '''    static_assert(
        offsetof(PageTracker, tracker_) + sizeof(tracker_) <=
            2 * ABSL_CACHELINE_SIZE,
        "tracker_ should fall within the first two cachelines of PageTracker.");''',
'''    // TPPT: the 8 MiB tracking bitmap needs a third cacheline.
    static_assert(
        offsetof(PageTracker, tracker_) + sizeof(tracker_) <=
            (kHugePageShift == 23 ? 3 : 2) * ABSL_CACHELINE_SIZE,
        "tracker_ exceeds its PageTracker cacheline budget.");''')
patch("tcmalloc/central_freelist.cc", '''    PrefetchW(reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(pt) +
                                      ABSL_CACHELINE_SIZE));''',
'''    PrefetchW(reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(pt) +
                                      ABSL_CACHELINE_SIZE));
    // Match the larger PageTracker cacheline budget for the TPPT experiment.
    if constexpr (kHugePageShift == 23) {
      PrefetchW(reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(pt) +
                                        2 * ABSL_CACHELINE_SIZE));
    }''')
PY

mkdir -p "$BUILD_DIR"
if (( graph_selected )); then
    make -C "$GRAPHBIG_DIR/tools"
    cp "$GRAPHBIG_DIR/tools/lib/libpfm.a" "$BUILD_DIR/libpfm.a"
    cp "$GRAPHBIG_DIR/tools/lib/libpfm_cxx.a" "$BUILD_DIR/libpfm_cxx.a"
fi
declare -A destinations=()
targets=()
for name in "${workloads[@]}"; do
    mkdir -p "$BUILD_DIR/$name"
    case "$name" in
        xsbench)
            for source in Main io Simulation CalculateXS GridInit XSutils Materials; do
                gcc -std=gnu99 -O3 -Wall -Wextra -fPIC -fpie -msse2 -mfpmath=sse \
                    -I"$MEM_APP_DIR/xsbench/src" \
                    -c "$MEM_APP_DIR/xsbench/src/$source.c" -o "$BUILD_DIR/$name/$source.o"
            done
            destinations[$name]="$MEM_APP_DIR/xsbench"
            ;;
        gups)
            # Match `gcc gups.c -o gups`: no optimization or OpenMP macro.
            gcc -O0 -c "$MEM_APP_DIR/gups/gups.c" -o "$BUILD_DIR/$name/gups.o"
            destinations[$name]="$MEM_APP_DIR/gups"
            ;;
        btree)
            gcc -std=gnu99 -Wall -O3 -c "$MEM_APP_DIR/btree/btree.c" \
                -o "$BUILD_DIR/$name/btree.o"
            destinations[$name]="$MEM_APP_DIR/btree"
            ;;
        *)
            case "$name" in
                dc) source=bench_degreeCentr/dc ;;
                pr) source=bench_pageRank/pagerank ;;
                bfs) source=bench_BFS/bfs ;;
                dfs) source=bench_DFS/dfs ;;
                sssp) source=bench_shortestPath/sssp ;;
                tc) source=bench_triangleCount/tc ;;
                cc) source=bench_connectedComp/connectedcomponent ;;
            esac
            flags=(-std=c++0x -O3 -Wall -Wno-deprecated -DUSE_OMP)
            if [[ $name != dfs ]]; then
                flags+=(-fopenmp -g)
            fi
            g++ "${flags[@]}" -I"$GRAPHBIG_DIR/common" -I"$GRAPHBIG_DIR/openG" \
                -I"$GRAPHBIG_DIR/tools/include" \
                -c "$GRAPHBIG_DIR/benchmark/$source.cpp" -o "$BUILD_DIR/$name/$name.o"
            destinations[$name]="$GRAPHBIG_DIR/bin"
            ;;
    esac
    targets+=("//:${name}_tcmalloc")
done

# Use one generated workspace and one allocator build per variant.
python3 - "$BUILD_DIR" "${workloads[@]}" <<'PY'
from pathlib import Path
import json, sys
build = Path(sys.argv[1])
text = '''load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
'''
if any(n not in ("xsbench", "gups", "btree") for n in sys.argv[2:]):
    text += '''cc_library(name = "pfm", srcs = ["libpfm.a"])
cc_library(name = "pfm_cxx", srcs = ["libpfm_cxx.a"], deps = [":pfm"])
'''
for name in sys.argv[2:]:
    # Explicit object lists exclude artifacts from other selected workloads.
    objects = [f"{name}/{n}.o" for n in
               ("Main", "io", "Simulation", "CalculateXS", "GridInit", "XSutils", "Materials")
               ] if name == "xsbench" else [f"{name}/{name}.o"]
    deps = [] if name in ("xsbench", "gups", "btree") else [":pfm_cxx"]
    text += '''cc_binary(
    name = %s,
    srcs = %s,
    deps = %s,
    malloc = "@tcmalloc//tcmalloc:tcmalloc",
    linkstatic = True,
    # On Focal, weak pthread references can leave a partially linked thread
    # runtime in static binaries without OpenMP. Force the required entry points
    # into the static link, including pthread_create for thread initialization.
    linkopts = ["-static", "-lgomp", "-ldl",
                "-Wl,-u,pthread_create,-u,pthread_mutex_lock,-u,pthread_mutex_unlock,-u,pthread_once",
                "-pthread", "-lm"],
)
''' % (json.dumps(name + "_tcmalloc"), json.dumps(objects), json.dumps(deps))
(build / "BUILD.bazel").write_text(text)
PY

cd "$BUILD_DIR"
for variant in 2m 8m; do
    python3 - "$BUILD_DIR" "$tmp_dir/tcmalloc-$variant" <<'PY'
from pathlib import Path
import json, sys
(Path(sys.argv[1]) / "MODULE.bazel").write_text('''module(name = "tppt_thp_tcmalloc")
bazel_dep(name = "rules_cc", version = "0.2.18")
bazel_dep(name = "tcmalloc", version = "0")
local_path_override(module_name = "tcmalloc", path = %s)
single_version_override(module_name = "abseil-cpp", version = "20260526.0")
''' % json.dumps(sys.argv[2]))
PY
    /usr/local/bin/bazel --batch --ignore_all_rc_files build \
        --jobs=4 --compilation_mode=opt \
        --cxxopt=-std=c++17 \
        --cxxopt=-Wno-error=c++20-extensions \
        --cxxopt=-Wno-error=thread-safety-precise \
        --repo_env=CC=/usr/bin/clang-22 \
        --repo_env=CXX=/usr/bin/clang++-22 \
        "${targets[@]}" @tcmalloc//tcmalloc/testing:hello_main
    ./bazel-bin/external/tcmalloc+/tcmalloc/testing/hello_main \
        | tee "$tmp_dir/hello_$variant.log"
    awk '/Current heap size =/ && $5 >= 2147483648 { ok = 1 }
         END { exit !ok }' "$tmp_dir/hello_$variant.log"
    mkdir "$tmp_dir/bin-$variant"
    for name in "${workloads[@]}"; do
        nm -n "bazel-bin/${name}_tcmalloc" | awk '
            $3 == "malloc" { m = $1 }
            $3 == "TCMallocInternalMalloc" { t = $1 }
            $3 == "pthread_mutex_lock" { lock = $1 }
            $3 == "pthread_mutex_unlock" { unlock = $1 }
            $3 == "pthread_once" { once = $1 }
            $3 == "pthread_key_create" { key = $1 }
            END { exit !(m != "" && m == t && lock != "" &&
                         unlock != "" && once != "" && key != "") }'
        readelf -l "bazel-bin/${name}_tcmalloc" > "$tmp_dir/elf.txt"
        if grep -q INTERP "$tmp_dir/elf.txt"; then
            echo "$name must be statically linked." >&2
            exit 1
        fi
        cp "bazel-bin/${name}_tcmalloc" "$tmp_dir/bin-$variant/${name}_tcmalloc_$variant"
    done
done

# Install only after every requested build and check passed.
for name in "${workloads[@]}"; do
    install -d -m 755 "${destinations[$name]}"
    for variant in 2m 8m; do
        install -m 755 "$tmp_dir/bin-$variant/${name}_tcmalloc_$variant" \
            "${destinations[$name]}/${name}_tcmalloc_$variant"
        echo "Installed ${destinations[$name]}/${name}_tcmalloc_$variant"
    done
done
cp "$tmp_dir/hello_2m.log" "$INSTALL_DIR/hello_thp_2m.log"
cp "$tmp_dir/hello_8m.log" "$INSTALL_DIR/hello_thp_8m.log"
