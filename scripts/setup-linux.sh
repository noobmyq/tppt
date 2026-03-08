set -euo pipefail
NUM_CORES=$(nproc)
if [ "$NUM_CORES" -gt 30 ]; then
	    NUM_CORES=30
fi
cd ..
pushd qemu-linux
git checkout my-qemu
./setup-qemu.sh
make -C build -j30

cp build/compile_commands.json .
popd

pushd shadow_pgtbl_kernel
git checkout main
cp cur_config .config
make olddefconfig
bear -- make -j${NUM_CORES}
popd

# create disk image

