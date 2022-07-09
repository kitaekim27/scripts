#!/bin/bash
#   ____            _                _     _
#  / ___| ___ _ __ | |_ ___   ___   | |   (_)_ __  _   ___  __
# | |  _ / _ \ '_ \| __/ _ \ / _ \  | |   | | '_ \| | | \ \/ /
# | |_| |  __/ | | | || (_) | (_) | | |___| | | | | |_| |>  <
#  \____|\___|_| |_|\__\___/ \___/  |_____|_|_| |_|\__,_/_/\_\
#
#  ___           _        _ _
# |_ _|_ __  ___| |_ __ _| | | ___ _ __
#  | || '_ \/ __| __/ _` | | |/ _ \ '__|  Author: Kitae Kim
#  | || | | \__ \ || (_| | | |  __/ |     Email:  kitaekim27 at gmail.com
# |___|_| |_|___/\__\__,_|_|_|\___|_|     Desc:   A shell script for automating
#                                                 installation of Gentoo Linux.
#

set -o errexit -o nounset -o noglob -o pipefail

info() {
    echo "$(basename "$0"):" "$@"
}

error() {
    info "$@" >&2
}

getpassphrase() {
    while true
    do
        read -srp "${1?}" "${2?}"
        echo
        read -srp "Enter a passphrase again: " checkphrase
        echo

        if [ "$(eval echo "\$${2?}")" = "${checkphrase?}" ]
        then
            break
        else
            info "You've entered different passphrases! Try again."
        fi
    done
}

if [ "$EUID" != 0 ]
then
    error "This script requires root privilege!"
    exit 1
fi

info "Sync the system time with ntp.org."
ntpd -q -g

info "Configure Portage mirrors."
mirrorselect --servers="5"

info "Install my scripts into the system."
find tools -mindepth 1 -maxdepth 1 \
    -exec cp --verbose --recursive {} /usr/local/bin/ \;

# TODO: Currently tpm2-tools package is in testing branch. So you need to unmask
#       it to install. Remove --autounmask flag when it's in stable branch.
info "Install package tpm2-tools."
emerge --autounmask --autounmask-write --autounmask-only app-crypt/tpm2-tools
dispatch-conf
emerge app-crypt/tpm2-tools

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
read -rp "Select an efi partition: " partition_uefi
read -rp "Select a swap partition: " partition_swap

info "Format an efi partition in vfat."
mkfs.vfat "/dev/$partition_uefi"

info "Set swap on $partition_swap."
mkswap "/dev/$partition_swap"
swapon "/dev/$partition_swap"

info "Seal a random key into TPM."
tpmsealrandkey

info "Create a LUKS2 passphrase for the root partition."
getpassphrase "Enter a passphrase for the root partition: " passphrase
luks_passphrase=$(mkpassphrase "${passphrase?}" | sed -n "s/result = \(.*\)/\1/p")

info "Encrypt the root partition."
echo "$luks_passphrase" | xxd -revert -plain | cryptsetup luksFormat \
    --type="luks2" \
    --key-file="-" \
    "/dev/$partition_root"

info "Add a recovery passphrase for the root partition."
getpassphrase "Enter a recovery passphrase for the root partition: " recovery_passphrase
echo "$luks_passphrase" | xxd -revert -plain | cryptsetup luksAddKey \
    --key-file="-" \
    "/dev/$partition_root" \
    <(echo "${recovery_passphrase?}")

info "Decrypt the root partition."
echo "$luks_passphrase" | xxd -revert -plain | cryptsetup luksOpen \
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

readonly install_root="/mnt/root/deploy/image-a"

info "Extract the stage 3 tarball into $install_root."
find download -iname "stage3-*.tar.xz" -exec tar \
    --directory="$install_root" \
    --extract --preserve-permissions --file={} \
    --xattrs-include='*.*' --numeric-owner \;

info "Configure the DNS of the installation."
cp --dereference /etc/resolv.conf "$install_root/etc/resolv.conf"

info "Install config files into the installation."
find config -mindepth 1 -maxdepth 1 \
    -exec cp --recursive --preserve {} "$install_root" \;

info "Install my scripts into the installation."
find tools -mindepth 1 -maxdepth 1 \
    -exec cp --recursive {} "$install_root/usr/local/bin/" \;

info "Set the initramfs source directory in the installation."
for dir in mnt/root usr/bin usr/local/bin bin sbin dev proc sys
do
    mkdir --parents "$install_root/usr/src/initramfs/$dir"
done
find initramfs -mindepth 1 -maxdepth 1 \
    -exec cp --recursive {} "$install_root/usr/src/initramfs" \;

info "Mount the proc filesystem in the installation."
mount --types proc /proc "$install_root/proc"

info "Mount the sys fileseystem in the installation."
mount --rbind /sys "$install_root/sys"
mount --make-rslave "$install_root/sys"

info "Mount the dev filesystem in the installation."
mount --rbind /dev "$install_root/dev"
mount --make-rslave "$install_root/dev"

info "Mount the run filesystem in the installation."
mount --bind /run "$install_root/run"
mount --make-rslave "$install_root/run"

chroot_main() {
    info "Mount an efi partition."
    mount "/dev/$partition_uefi" /boot

    info "Configure Portage ebuild repositories."
    mkdir --parents /etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf

    info "Install system management tools."
    emerge app-portage/gentoolkit
    emerge app-portage/mirrorselect
    emerge sys-fs/btrfs-progs

    info "Enable some system-wide USE flags."
    euse --enable bluetooth networkmanager

    info "Configure Portage mirrors."
    mirrorselect --servers="5"

    info "Install a snapshot of the Gentoo ebuild repository."
    emerge-webrsync

    info "Choose a Portage profile."
    eselect profile list
    read -rp "Select a Portage profile: " profile
    eselect profile set "$profile"

    if [ -d /etc/portage/package.use ]
    then
        info "Make the Portage package.use a single file."
        rm --recursive /etc/portage/package.use
        touch /etc/portage/package.use
    fi

    info "Update @world Portage set."
    emerge --update --deep --newuse @world

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

    if grep --quiet --ignore-case "AMD" /proc/cpuinfo
    then
        info "AMD CPU detected. Install AMD microcodes."
        # AMD microcodes are shipped in the sys-kernel/linux-firmware package.
        info "Enable USE flag \"initramfs\" of sys-kernel/linux-firmware"
        echo "sys-kernel/linux-firmware initramfs" >> /etc/portage/package.use

    elif grep --quiet --ignore-case "Intel" /proc/cpuinfo
    then
        info "Intel CPU detected. Install Intel microcodes."
        info "Enable USE flag \"initramfs\" of sys-firmware/intel-microcode"
        # This USE flag generates microcode cpio at /boot so that GRUB automatically
        # detect and generate config with it.
        echo "sys-firmware/intel-microcode initramfs" >> /etc/portage/package.use

        info "Install the intel microcode package."
        emerge sys-firmware/intel-microcode
    else
        info "Can not determine CPU manufacturer. Do not install microcodes."
    fi

    info "Install the linux firmwares."
    emerge --autounmask --autounmask-license --autounmask-write --autounmask-only \
        sys-kernel/linux-firmware

    info "Install the linux kernel sources."
    emerge sys-kernel/gentoo-sources

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

    info "Install packages for building an initramfs."
    emerge sys-apps/busybox
    emerge sys-fs/cryptsetup
    emerge app-arch/lz4

    # TODO: Currently tpm2-tools package is in testing branch. So you need to unmask
    #       it to install. Remove --autounmask flag when it's in stable branch.
    info "Install tpm2-tools to build an initramfs."
    emerge --autounmask --autounmask-write --autounmask-only app-crypt/tpm2-tools
    dispatch-conf
    emerge app-crypt/tpm2-tools

    info "Build and install an initramfs."
    mkinitramfs

    info "Generate the fstab."
    PARTUUID_UEFI=$(blkid -o value -s PARTUUID "/dev/$partition_uefi") \
    PARTUUID_SWAP=$(blkid -o value -s PARTUUID "/dev/$partition_swap") \
    PARTUUID_ROOT=$(blkid -o value -s PARTUUID "/dev/$partition_root") \
        envsubst < config/etc/fstab.tmpl > /etc/fstab

    info "Set the hostname."
    read -rp "Enter the hostname: " hostname
    sed -i "s/localhost/$hostname/g" /etc/conf.d/hostname /etc/hosts

    info "Install NetworkManager."
    emerge net-misc/networkmanager
    rc-update add NetworkManager default

    info "Install rsyslog."
    emerge app-admin/rsyslog
    rc-update add rsyslog default
}

info "chroot into $install_root and execute chroot_main()."
chroot "$install_root" /bin/bash -c "
    set -o errexit -o nounset -o noglob -o pipefail
    root_storage=$root_storage
    partition_uefi=$partition_uefi
    partition_swap=$partition_swap
    partition_root=$partition_root
    $(declare -f info)
    $(declare -f error)
    $(declare -f chroot_main)
    chroot_main
"
