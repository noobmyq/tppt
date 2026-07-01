#!/bin/bash

set -exuo pipefail

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
BASE_DIR=$SCRIPT_DIR/..

TRACER_DIR=$BASE_DIR/tracer
SIMULATOR_DIR=$BASE_DIR/dynamorio-puresim
WORKLOAD_DIR=$BASE_DIR/workloads

pushd $WORKLOAD_DIR
git checkout main
./make_all.sh
popd

pushd $TRACER_DIR
git checkout main

if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
fi

sg docker -c './build_dynamorio.sh'
cd dump_pagetables
make clean
./install.sh
cd ..
popd

pushd $SIMULATOR_DIR
git checkout no-pgtbl-load
# tp version of thp
./build_thp_version.sh

git checkout dmt
# this is the vanilla version of thp
./build_vanilla_thp.sh

git checkout no-pgtbl-load
popd

