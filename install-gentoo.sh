#!/bin/bash

set -o errexit -o nounset -o noglob -o pipefail

this_script=$(basename "$0")

info() {
    echo "$this_script:" "$@"
}

error() {
    info "$@" >&2
}

if [ "$EUID" != 0 ]
then
    error "this script requires root privilege!"
    exit 1
fi

info "sync time with ntp.org"
ntpd -q -g

info "configure Portage mirrors of the installer"
mirrorselect --servers="5"

info "Install my scripts."
find tools -exec install --verbose {} /usr/local/bin/ \;

# note that currently tpm2-tools package is in testing branch. that means, you
# need to unmask the package to install. remove --autounmask flag when
# tpm2-tools package is in stable branch.
info "install tpm2-tools package"
# FIXME: for some reason, emerge with --autounmask returns 1 when it succeeds
emerge --ask --tree --verbose --autounmask app-crypt/tpm2-tools || [ "$?" = 1 ]
dispatch-conf
emerge --ask --tree --verbose app-crypt/tpm2-tools

# check if we have space in TPM for persistent handle of an encryption key
if [ "$(tpm2_getcap properties-variable \
    | sed -n 's/TPM2_PT_HR_PERSISTENT_AVAIL: \(.*\)/\1/p')" = 0x0 ]
then
    error "there's no space available to store an encryption key in TPM!"
    exit 1
fi

if ! ping -q -c 1 -W 1 google.com >/dev/null
then
    error "can not connect to the internet!"
    exit 1
fi

lsblk
read -rp "select a root storage device: " root_storage
fdisk "/dev/$root_storage"
sync

lsblk
read -rp "select a root filesystem partition: " partition_rootfs
read -rp "select an efi boot partition: " partition_efi
read -rp "select a swap partition: " partition_swap

info "format an efi boot partition in vfat"
mkfs.vfat "/dev/$partition_efi"

info "set swap on $partition_swap"
mkswap "/dev/$partition_swap"
swapon "/dev/$partition_swap"

tmpdir=$(mktemp -d)

info "generate a primary TPM object in the endorsement hierarchy"
tpm2_createprimary --quiet --hierarchy="e" --key-context="$tmpdir/primary.ctx"

info "start a TPM HMAC trial session for building a policy"
tpm2_startauthsession --session="$tmpdir/session.bin"

info "generate a TPM policy with sha256 bank of PCR 0,2,4,8,9"
tpm2_policypcr \
    --quiet \
    --session="$tmpdir/session.bin" \
    --pcr-list="sha256:0,2,4,8,9" \
    --policy="$tmpdir/policy.bin"

info "seal a random key in a TPM object with the policy"
dd if=/dev/urandom bs=128 count=1 status=none | tpm2_create \
    --quiet \
    --parent-context="$tmpdir/primary.ctx" \
    --policy="$tmpdir/policy.bin" \
    --key-context="$tmpdir/key.ctx" \
    --sealing-input="-"

# note that 0x81018000 is the first not-reserved persistent object handle in the
# endorsement hierarchy
# see: TCG, "Registry of Reserved TPM 2.0 Handles and Localities"
info "make the generated key persistent in TPM"
# try to evict existing object at 0x81018000 first
# XXX: make sure that there are no important objects at 0x81018000.
tpm2_evictcontrol --object-context="0x81018000" 2>/dev/null || :
tpm2_evictcontrol --object-context="$tmpdir/key.ctx" 0x81018000

info "create a LUKS2 passphrase for a root filesystem"
read -srp "enter a passphrase: " passphrase
echo
luks_passphrase=$(mkpassphrase "$passphrase" | sed -n 's/result = \(.*\)/\1/p')

info "encrypt a root filesystem partition"
echo "$luks_passphrase" \
    | xxd -revert -plain \
    | cryptsetup luksFormat \
        --type="luks2" \
        --key-file="-" \
        "/dev/$partition_rootfs"

info "add a recovery passphrase"
read -srp "enter a recovery passphrase: " recovery_passphrase
echo
echo "$luks_passphrase" \
    | xxd -revert -plain \
    | cryptsetup luksAddKey \
        --key-file="-" \
        "/dev/$partition_rootfs" \
        <(echo "$recovery_passphrase")

info "decrypt a root filesystem partition"
echo "$luks_passphrase" \
    | xxd -revert -plain \
    | cryptsetup luksOpen \
        --key-file="-" \
        "/dev/$partition_rootfs" \
        root

info "format a root partition in btrfs"
mkfs.btrfs /dev/mapper/root

info "mount a root filesystem partition"
mkdir -vp /mnt/root
mount /dev/mapper/root /mnt/root

info "set the filesystem hierarchy layout"
mkdir -vp /mnt/root/boot
mkdir -vp /mnt/root/deploy/{image-a,image-b}
mkdir -vp /mnt/root/snapshots

# TODO: verify the downloaded files
info "download a stage 3 tarball"
arch="amd64"
mirror="http://ftp.kaist.ac.kr/gentoo/releases"
wget --recursive --no-parent --no-directories \
    --directory-prefix="download" \
    --accept="stage3-$arch-hardened-openrc-*" \
    "$mirror/$arch/autobuilds/current-stage3-$arch-openrc/"

install_path="/mnt/root/deploy/image-a"

info "extract a stage3 tarball into $install_path"
find download -iname "stage3-*.tar.xz" -exec tar \
    --directory="$install_path" \
    --extract --preserve-permissions --file={} \
    --xattrs-include='*.*' --numeric-owner \;

info "configure DNS info"
cp -vL /etc/resolv.conf "$install_path/etc/"

info "Install my scripts into the installation."
find tools -exec install --verbose {} "$install_path/usr/local/bin/" \;

info "mount the linux filesystems"
mount --types proc /proc "$install_path/proc"
mount --rbind /sys "$install_path/sys"
mount --make-rslave "$install_path/sys"
mount --rbind /dev "$install_path/dev"
mount --make-rslave "$install_path/dev"
mount --bind /run "$install_path/run"
mount --make-rslave "$install_path/run"

chroot_main() {
    source /etc/profile

    info "mount an efi boot partition"
    mount "/dev/$partition_efi" /boot

    info "configure Portage compile flags"
    sed -i 's/COMMON_FLAGS=".*"/COMMON_FLAGS="-O2 -pipe -march=native"/' \
        /etc/portage/make.conf
    cat << EOF >> /etc/portage/make.conf
# Note that it's recommended to have at least 2GB of RAM for each jobs.
MAKEOPTS="-j$(nproc)"
EOF

    info "configure Portage mirrors"
    mirrorselect --servers="5"

    info "configure Portage ebuild repositories"
    mkdir -vp /etc/portage/repos.conf
    cp -v /usr/share/portage/config/repos.conf \
        /etc/portage/repos.conf/gentoo.conf

    info "install a snapshot of the Gentoo ebuild repository"
    emerge-webrsync

    info "choose a Portage profile"
    eselect profile list
    read -rp "select a Portage profile by index number: " profile
    eselect profile set "$profile"

    info "update @world Portage set"
    emerge --ask --verbose --update --deep --newuse @world

    info "configure timezone to Asia/Seoul"
    echo "Asia/Seoul" > /etc/timezone
    emerge --config sys-libs/timezone-data

    info "generate locales"
    nano -w /etc/locale.gen
    locale-gen

    info "configure locales"
    eselect locale list
    read -rp "select a locale by index number: " locale
    eselect locale set "$locale"

    info "reload the environment"
    env-update
    source /etc/profile

    # TODO: install microcodes
    info "install linux firmwares"
    emerge --ask --tree --verbose sys-kernel/linux-firmwares

    info "install the linux kernel sources"
    emerge --ask --tree --verbose sys-kernel/gentoo-sources

    # It is conventional for a /usr/src/linux symlink to be maintained, such
    # that it refers to whichever sources correspond with the currently running
    # kernel.
    info "create a symlink /usr/src/linux"
    eselect kernel list
    read -rp "select a kernel by index number: " kernel
    eselect kernel set "$kernel"

    make="make --directory=/usr/src/linux --jobs=$(nproc)"

    info "configure the linux kernel"
    $make menuconfig

    info "compile and install the linux kernel"
    $make
    $make modules_install
    # this will copy the kernel image into /boot together with the System.map
    # file and the kernel configuration file.
    $make install

    info "Set the basic initramfs directory."
    mkdir -p /usr/src/initramfs/{mnt/root,dev,proc,sys}
    find initramfs -exec install --verbose {} /usr/src/initramfs/ \;

    info "install dependencies for building an initramfs"
    emerge --ask --tree --verbose sys-apps/busybox
    emerge --ask --tree --verbose sys-fs/cryptsetup
    emerge --ask --tree --verbose app-arch/lz4

    # note that currently tpm2-tools package is in testing branch. that means, you
    # need to unmask the package to install. remove --autounmask flag when
    # tpm2-tools package is in stable branch.
    info "install tpm2-tools for building an initramfs"
    # FIXME: for some reason, emerge with --autounmask returns 1 when it succeeds
    emerge --ask --tree --verbose --autounmask app-crypt/tpm2-tools || [ "$?" = 1 ]
    dispatch-conf
    emerge --ask --tree --verbose app-crypt/tpm2-tools

    info "build and install an initramfs"
    mkinitramfs
}

info "chroot into $install_path and execute chroot_main()"
chroot "$install_path" /bin/bash -c "
    this_script=$this_script
    root_storage=$root_storage
    partition_efi=$partition_efi
    partition_swap=$partition_swap
    partition_rootfs=$partition_rootfs
    $(declare -f info)
    $(declare -f error)
    $(declare -f chroot_main)
    chroot_main
"
