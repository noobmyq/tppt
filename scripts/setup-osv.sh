set -exuo pipefail

NUM_CORES=$(nproc)
if [ "$NUM_CORES" -gt 30 ]; then
    NUM_CORES=30
fi
cd ..
pushd workloads
SRC="qemu-dynamorio-workload/osv-workload"
DEST="../osv/apps"

# Loop through every file in the source directory
for file in "$SRC"/*; do
    # Get just the filename (e.g., "btree" instead of "path/to/btree")
    filename=$(basename "$file")

    # Check if the filename is NOT "readme"
    if [ "$filename" != "readme" ]; then
        # Create the link using Absolute Path ($PWD) to avoid broken links
        ln -s "$PWD/$file" "$DEST/"
    fi
done
popd

pushd qemu
git checkout osv-qemu
./setup-qemu.sh
make -C build -j${NUM_CORES}
popd

pushd osv
git checkout vanilla
sudo ./scripts/setup.py
export CFLAGS="-Wno-error"
export CXXFLAGS="-Wno-error"
#test a build
./scripts/build -j4 fs=rofs image=native-example
cd apps/graphbig
# if this takes a long time, try to download manually
# it seems that the server is crashed sometimes
./get_dataset.sh "social_network-sf10-numpart-1"
./get_dataset.sh "social_network-sf3-numpart-1"
# configure memcached
cd ../memcached-osv
./autogen.sh
./configure LDFLAGS="-static"
# configure sysbench
cd ../sysbench
./autogen.sh
./configure --prefix=$(pwd)/build --without-mysql
# get dataset for canneal
cd ../canneal
pip install gdown
~/.local/bin/gdown 1gQbEGW-Z6oCo0zRIorF1AEo9JJEV5Vob
mv canneal canneal-dataset
cd ..
popd

pushd osv-dynamorio
git checkout qemu-dynamorio
# we might have a newer glibc
sed -i '147s/FATAL_ERROR/STATUS/' core/CMake_readelf.cmake
./build_dynamorio.sh osv
popd
