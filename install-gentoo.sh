#!/bin/bash

set -o errexit -o nounset -o noglob -o pipefail

THIS_SCRIPT=$(basename "$0")
readonly THIS_SCRIPT

info() {
    echo "$THIS_SCRIPT:" "$@"
}

error() {
    info "$@" >&2
}

if [ "$EUID" != 0 ]
then
    error "This script requires root privilege!"
    exit 1
fi

info "Sync the system time with ntp.org."
ntpd -q -g

info "Configure Portage mirrors of the system."
mirrorselect --servers="5"

info "Install my scripts into the system."
find tools -mindepth 1 -maxdepth 1 \
    -exec cp --verbose --recursive {} /usr/local/bin/ \;

# Note that currently tpm2-tools package is in testing branch. that means, you
# need to unmask the package to install. Remove --autounmask flag when
# tpm2-tools package is in stable branch.
info "Install package tpm2-tools."
# FIXME: For some reason, emerge with --autounmask returns 1 when it succeeds.
emerge --ask --tree --verbose --autounmask app-crypt/tpm2-tools || [ "$?" = 1 ]
dispatch-conf
emerge --tree --verbose app-crypt/tpm2-tools

# Check if we have any persistent handle in TPM for an encryption key.
if [ "$(tpm2 getcap properties-variable \
    | sed -n 's/TPM2_PT_HR_PERSISTENT_AVAIL: \(.*\)/\1/p')" = 0x0 ]
then
    error "There's no available persistent handle in TPM to store an encryption key!"
    exit 1
fi

if ! ping -q -c 1 -W 1 google.com >/dev/null
then
    error "Can not connect to the internet!"
    exit 1
fi

lsblk
read -rp "Select a root storage: " root_storage
fdisk "/dev/$root_storage"
sync

lsblk
read -rp "Select a root partition: " partition_root
read -rp "Select an efi partition: " partition_efi
read -rp "Select a swap partition: " partition_swap

info "Format an efi partition in vfat."
mkfs.vfat "/dev/$partition_efi"

info "Set swap on $partition_swap."
mkswap "/dev/$partition_swap"
swapon "/dev/$partition_swap"

tmpdir=$(mktemp --directory)
readonly tmpdir

info "Create a primary object in the endorsement hierarchy."
tpm2 createprimary --quiet --hierarchy="e" --key-context="$tmpdir/primary.ctx"

info "Start a TPM HMAC trial session for building a policy."
tpm2 startauthsession --session="$tmpdir/session.bin"

info "Generate a TPM policy with sha256 bank of PCR 0,2,4,8,9."
tpm2 policypcr \
    --quiet \
    --session="$tmpdir/session.bin" \
    --pcr-list="sha256:0,2,4,8,9" \
    --policy="$tmpdir/policy.bin"

info "Seal a random key into a TPM object with the policy."
dd if=/dev/urandom bs=128 count=1 status=none | tpm2 create \
    --quiet \
    --parent-context="$tmpdir/primary.ctx" \
    --policy="$tmpdir/policy.bin" \
    --key-context="$tmpdir/key.ctx" \
    --sealing-input="-"

# Note that 0x81018000 is the first non-reserved persistent object handle in the
# endorsement hierarchy.
# See: TCG, "Registry of Reserved TPM 2.0 Handles and Localities"
info "Make the generated key object persistent in TPM."
# Try to evict existing object at 0x81018000 first.
# XXX: Make sure that there are no important objects at 0x81018000.
tpm2 evictcontrol --object-context="0x81018000" 2>/dev/null || :
tpm2 evictcontrol --object-context="$tmpdir/key.ctx" 0x81018000

info "Create a LUKS2 passphrase for the root partition."
read -srp "Enter a passphrase for the root partition: " passphrase
echo
luks_passphrase=$(mkpassphrase "$passphrase" | sed -n "s/result = \(.*\)/\1/p")

info "Encrypt the root partition."
echo "$luks_passphrase" \
    | xxd -revert -plain \
    | cryptsetup luksFormat \
        --type="luks2" \
        --key-file="-" \
        "/dev/$partition_root"

info "Add a recovery passphrase for the root partition."
read -srp "Enter a recovery passphrase for the root partition: " recovery_passphrase
echo
echo "$luks_passphrase" \
    | xxd -revert -plain \
    | cryptsetup luksAddKey \
        --key-file="-" \
        "/dev/$partition_root" \
        <(echo "$recovery_passphrase")

info "Decrypt the root partition."
echo "$luks_passphrase" \
    | xxd -revert -plain \
    | cryptsetup luksOpen \
        --key-file="-" \
        "/dev/$partition_root" \
        root

info "Format the root partition in btrfs."
mkfs.btrfs /dev/mapper/root

info "Mount the root partition."
mkdir --parents /mnt/root
mount /dev/mapper/root /mnt/root

info "Set the filesystem hierarchy layout in the root partition."
mkdir --parents /mnt/root/boot
mkdir --parents /mnt/root/deploy/{image-a,image-b}
mkdir --parents /mnt/root/snapshots

# TODO: Verify the downloaded files.
info "Download a stage 3 tarball."
readonly ARCH="amd64"
readonly MIRROR="http://ftp.kaist.ac.kr/gentoo/releases"
wget --recursive --no-parent --no-directories \
    --directory-prefix="download" \
    --accept="stage3-$ARCH-hardened-openrc-*" \
    "$MIRROR/$ARCH/autobuilds/current-stage3-$ARCH-openrc/"

readonly INSTALL_ROOT="/mnt/root/deploy/image-a"

info "Extract the stage 3 tarball into $INSTALL_ROOT."
find download -iname "stage3-*.tar.xz" -exec tar \
    --directory="$INSTALL_ROOT" \
    --extract --preserve-permissions --file={} \
    --xattrs-include='*.*' --numeric-owner \;

info "Configure the DNS of the installation."
cp --dereference /etc/resolv.conf "$INSTALL_ROOT/etc/resolv.conf"

info "Install my scripts into the installation."
find tools -mindepth 1 -maxdepth 1 \
    -exec cp --recursive {} "$INSTALL_ROOT/usr/local/bin/" \;

info "Mount the proc filesystem in the installation."
mount --types proc /proc "$INSTALL_ROOT/proc"

info "Mount the sys fileseystem in the installation."
mount --rbind /sys "$INSTALL_ROOT/sys"
mount --make-rslave "$INSTALL_ROOT/sys"

info "Mount the dev filesystem in the installation."
mount --rbind /dev "$INSTALL_ROOT/dev"
mount --make-rslave "$INSTALL_ROOT/dev"

info "Mount the run filesystem in the installation."
mount --bind /run "$INSTALL_ROOT/run"
mount --make-rslave "$INSTALL_ROOT/run"

chroot_main() {
    source /etc/profile

    info "Mount an efi partition."
    mount "/dev/$partition_efi" /boot

    info "Configure Portage compile flags."
    sed -i 's/COMMON_FLAGS=".*"/COMMON_FLAGS="-O2 -march=native -pipe"/p' \
        /etc/portage/make.conf
    echo "MAKEOPTS=\"--jobs=$(nproc)\"" >> /etc/portage/make.conf

    info "Configure Portage mirrors."
    mirrorselect --servers="5"

    info "Configure Portage ebuild repositories."
    mkdir --parents /etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf \
        /etc/portage/repos.conf/gentoo.conf

    info "Install a snapshot of the Gentoo ebuild repository."
    emerge-webrsync

    info "Choose a Portage profile."
    eselect profile list
    read -rp "Select a Portage profile: " profile
    eselect profile set "$profile"

    info "Update @world Portage set."
    emerge --verbose --update --deep --newuse @world

    info "Set the timezone to Asia/Seoul."
    echo "Asia/Seoul" > /etc/timezone
    emerge --config sys-libs/timezone-data

    info "Generate the locales."
    nano -w /etc/locale.gen
    locale-gen

    info "Configure the locales."
    eselect locale list
    read -rp "Select a locale: " locale
    eselect locale set "$locale"

    info "Reload the environment."
    env-update
    source /etc/profile

    # TODO: Install microcodes.
    info "Install the linux firmwares."
    emerge --tree --verbose sys-kernel/linux-firmwares

    info "Install the linux kernel sources."
    emerge --tree --verbose sys-kernel/gentoo-sources

    # /usr/src/linux symlink refers to the source tree corresponding with the
    # currently running kernel.
    info "Create a symlink /usr/src/linux."
    eselect kernel list
    read -rp "Select a kernel: " kernel
    eselect kernel set "$kernel"

    make="make --directory=/usr/src/linux --jobs=$(nproc)"

    info "Configure the linux kernel."
    $make menuconfig

    info "Compile and install the linux kernel."
    $make
    $make modules_install
    # This will copy the kernel image into /boot together with the System.map
    # file and the kernel configuration file.
    $make install

    info "Set the initramfs source directory."
    mkdir -p /usr/src/initramfs/{mnt/root,dev,proc,sys}
    find initramfs -mindepth 1 -maxdepth 1 \
        -exec cp --recursive {} /usr/src/initramfs/ \;

    info "Install packages for building an initramfs."
    emerge --tree --verbose sys-apps/busybox
    emerge --tree --verbose sys-fs/cryptsetup
    emerge --tree --verbose app-arch/lz4

    # Note that currently tpm2-tools package is in testing branch. that means, you
    # need to unmask the package to install. Remove --autounmask flag when
    # tpm2-tools package is in stable branch.
    info "Install tpm2-tools to build an initramfs."
    # FIXME: For some reason, emerge with --autounmask returns 1 when it succeeds.
    emerge --ask --tree --verbose --autounmask app-crypt/tpm2-tools || [ "$?" = 1 ]
    dispatch-conf
    emerge --tree --verbose app-crypt/tpm2-tools

    info "Build and install an initramfs."
    mkinitramfs
}

info "chroot into $INSTALL_ROOT and execute chroot_main()."
chroot "$INSTALL_ROOT" /bin/bash -c "
    set -o errexit -o nounset -o noglob -o pipefail
    readonly THIS_SCRIPT=$THIS_SCRIPT
    root_storage=$root_storage
    partition_efi=$partition_efi
    partition_swap=$partition_swap
    partition_root=$partition_root
    $(declare -f info)
    $(declare -f error)
    $(declare -f chroot_main)
    chroot_main
"
