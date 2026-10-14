#!/bin/bash
# Keep this script in same directory as the source image
# Usage: ./clone_win11_backup.sh <n>
# Where <n> is the number of copies to create

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_IMAGE="${SCRIPT_DIR}/win11_1.backup.qcow2"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <n>" >&2
    exit 1
fi

n="$1"

if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then
    echo "Error: n must be a positive integer" >&2
    exit 1
fi

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "Error: source image not found: $SOURCE_IMAGE" >&2
    exit 1
fi

for i in $(seq 1 "$n"); do
    dest="${SCRIPT_DIR}/win11_${i}.qcow2"
    cp "$SOURCE_IMAGE" "$dest"
    echo "Created $dest"
done
