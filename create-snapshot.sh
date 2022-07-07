#!/bin/bash
# create a snapshot of running root filesystem
set -o errexit -o nounset -o noglob -o pipefail

this_script=$(basename "$0")

if [ "$EUID" != 0 ]
then
    echo "$this_script requires root privilege" >&2
    exit 1
fi

snapshot=$(date -Iseconds)

echo "$this_script: create snapshot $snapshot"

btrfs subvolume snapshot -r \
    /host-rootfs/deploy/current \
    "/host-rootfs/snapshots/$snapshot"

echo "done"
