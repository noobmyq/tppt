#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
storage_dir=${STORAGE_DIR:-$(dirname "$repo_dir")}
orfs_dir=${ORFS_DIR:-$storage_dir/OpenROAD-flow-scripts}
jobs=${JOBS:-$(nproc)}

if ((jobs > 30)); then
    jobs=30
fi

git -C "$repo_dir" submodule update --init hardware_quantization

if [[ ! -d "$orfs_dir/.git" ]]; then
    git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git "$orfs_dir"
else
    git -C "$orfs_dir" submodule update --init --recursive
fi

sudo "$orfs_dir/setup.sh"
"$orfs_dir/build_openroad.sh" --local --threads "$jobs"
sudo apt-get install -y python3-matplotlib

yosys_bin=$orfs_dir/tools/install/yosys/bin/yosys
openroad_bin=$orfs_dir/tools/install/OpenROAD/bin/openroad
platform_dir=$orfs_dir/flow/platforms/nangate45

for path in \
    "$yosys_bin" \
    "$openroad_bin" \
    "$platform_dir/lef/NangateOpenCellLibrary.tech.lef" \
    "$platform_dir/lef/NangateOpenCellLibrary.macro.mod.lef" \
    "$platform_dir/lib/NangateOpenCellLibrary_typical.lib"; do
    if [[ ! -e "$path" ]]; then
        echo "Missing: $path" >&2
        exit 1
    fi
done

MPLCONFIGDIR=/tmp/tppt-matplotlib python3 -c 'import matplotlib'
"$yosys_bin" -V
"$openroad_bin" -version
printf 'ORFS_DIR=%s\n' "$orfs_dir"
