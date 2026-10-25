#!/bin/bash
# Compatibility entry point for building only BFS.
set -euo pipefail
if (( $# != 1 )); then
    echo "usage: $0 <workload-user>" >&2
    exit 2
fi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
builder=$SCRIPT_DIR/build-thp-tcmalloc.sh
if [[ ! -x $builder ]]; then
    builder=$SCRIPT_DIR/tppt-build-thp-tcmalloc
fi
exec "$builder" "$1" bfs
