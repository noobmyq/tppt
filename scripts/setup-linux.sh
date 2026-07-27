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

pushd qemu-linux
git checkout native-tp-support
if [ ! -f build/build.ninja ]; then
	./configure --target-list=x86_64-softmmu --enable-debug \
		--disable-linux-io-uring --enable-plugins
fi
make -C build -j${NUM_CORES}
cp build/compile_commands.json .
popd

pushd linux-tp
git checkout tppt/v6.8-clean
cp tppt_config .config
make olddefconfig
bear -- make -j${NUM_CORES}
popd

# create disk image
