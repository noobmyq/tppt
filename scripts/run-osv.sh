#!/bin/bash

set -euo pipefail

cd ../qemu

./run_all.sh

cd ../osv-dynamorio
./run_osv_all.sh ../qemu/results
