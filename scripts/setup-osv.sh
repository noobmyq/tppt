set -exuo pipefail

NUM_CORES=$(nproc)
if [ "$NUM_CORES" -gt 30 ]; then
    NUM_CORES=30
fi
cd ..
pushd workloads
git checkout main
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
./setup-qemu-32bit.sh
make -C build -j${NUM_CORES}
make -C build-32bit -j${NUM_CORES}
popd

pushd osv
git checkout vanilla
sudo ./scripts/setup.py
export CFLAGS="-Wno-error"
export CXXFLAGS="-Wno-error"
#test a build
./scripts/build -j4 fs=rofs image=xsbench mode=debug
cd apps/graphbig
# if this takes a long time, try to download manually
# it seems that the server is crashed sometimes
./get_dataset.sh "social_network-sf10-numpart-1" "snb"
./get_dataset.sh "social_network-sf30-numpart-1" "snb"
# download dataset for LDBC-1000k, this is a dense graph
~/.local/bin/gdown 'https://drive.google.com/uc?export=download&id=1fuk5tadoU4oHtXUNJUusQo868vS_-dSB' -O LDBC.tar
tar -xf LDBC.tar --directory .
# download dataset for sf300
~/.local/bin/gdown '155pf8uyxBN6bLfVAinjpr11CIgvqAUn9' --output sf300-dataset.zip
unzip sf300-dataset.zip -d ./snb-sf300

# make sure if LDBC/output-1000k folder exists
if [ ! -d "LDBC/output-1000k" ]; then
    echo "LDBC/output-1000k folder does not exist"
    exit 1
fi

rm LDBC.tar

# make sure if snb-sf300 folder exists
if [ ! -d "snb-sf300" ]; then
    echo "snb-sf300 folder does not exist"
    exit 1
fi

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
~/.local/bin/gdown 1gQbEGW-Z6oCo0zRIorF1AEo9JJEV5Vob -O canneal-dataset
head -n 5000000 canneal-dataset > canneal-dataset-small
cd ..
popd

pushd osv-dynamorio
git checkout qemu-dynamorio
# we might have a newer glibc
sed -i '147s/FATAL_ERROR/STATUS/' core/CMake_readelf.cmake
./build_dynamorio.sh osv
popd
