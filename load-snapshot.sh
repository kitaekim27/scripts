#!/bin/bash
# load the given snapshot
set -o errexit -o nounset -o noglob -o pipefail

this_script=$(basename "$0")

if [ "$EUID" != 0 ]
then
    echo "$this_script requires root privilege" >&2
    exit 1
fi

readonly snapshot="$1"

if [ "$(readlink /host-rootfs/deploy/current)" = "image-a" ]
then
    next_image="image-b"
else
    next_image="image-a"
fi

echo "load snapshot $snapshot as $next_image"

btrfs subvolume snapshot \
    "/host-rootfs/snapshots/$snapshot" \
    "/host-rootfs/deploy/$next_image"

rm /host-rootfs/deploy/target
ln -sf "$next_image" /host-rootfs/deploy/target

echo "done"
