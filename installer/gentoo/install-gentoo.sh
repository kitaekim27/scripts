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

this_script=$(basename "${0}")

info() {
	echo "${this_script}:" "${@}"
}

error() {
	info "${@}" >&2
}

get_passphrase() {
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

if [ "${EUID}" != 0 ]
then
	error "This script requires root privilege!"
	exit 1
fi

info "Sync the system time with ntp.org."
ntpd -q -g

info "Configure Portage mirrors."
mirrorselect --interactive

info "Install my scripts into the system."
find -L tools -mindepth 1 -maxdepth 1 \
	-exec cp --verbose --recursive {} /usr/local/bin/ \;

info "Install package tpm2-tools."
emerge --autounmask --autounmask-continue app-crypt/tpm2-tools

if ! nc -zw1 google.com 443
then
	error "Can not connect to the internet!"
	exit 1
fi

lsblk
read -rp "Select a root storage: " root_storage
fdisk "/dev/${root_storage}"
sync

lsblk
read -rp "Select a root partition: " partition_root
read -rp "Select an efi partition: " partition_uefi
read -rp "Select a swap partition: " partition_swap

info "Format an efi partition in vfat."
mkfs.vfat "/dev/${partition_uefi}"

info "Set swap on ${partition_swap}."
mkswap "/dev/${partition_swap}"
swapon "/dev/${partition_swap}"

info "Seal a random key into TPM."
tpmsealrandkey

info "Create a LUKS2 passphrase for the root partition."
get_passphrase "Enter a passphrase for the root partition: " passphrase
luks_passphrase=$(mkpassphrase "${passphrase?}" | sed -n "s/result = \(.*\)/\1/p")

info "Encrypt the root partition."
echo "${luks_passphrase}" | xxd -revert -plain | cryptsetup luksFormat \
	--type="luks2" \
	--key-file="-" \
	"/dev/${partition_root}"

info "Add a secondary passphrase for the root partition."
get_passphrase "Enter a secondary passphrase for the root partition: " secondary_passphrase
echo "${luks_passphrase}" | xxd -revert -plain | cryptsetup luksAddKey \
	--key-file="-" \
	"/dev/${partition_root}" \
	<(printf "%s" "${secondary_passphrase}")

info "Decrypt the root partition."
echo "${luks_passphrase}" | xxd -revert -plain | cryptsetup luksOpen \
	--key-file="-" \
	"/dev/${partition_root}" \
	root

info "Format the root partition in btrfs."
mkfs.btrfs /dev/mapper/root

info "Mount the root partition."
mkdir --parents /mnt/root
mount /dev/mapper/root /mnt/root

info "Set the filesystem hierarchy layout in the root partition."
mkdir --parents /mnt/root/boot
mkdir --parents /mnt/root/deploy
mkdir --parents /mnt/root/snapshots

info "Create a btrfs subvolume to install the system."
# Here, note that our initial subvolume is image-a.
btrfs subvolume create /mnt/root/deploy/image-a
ln --symbolic /deploy/image-a /mnt/root/deploy/current
ln --symbolic /deploy/image-a /mnt/root/deploy/target
# This makes mounttab valid so that we can see / mount entry inside the chroot.
mount --types="btrfs" --options="noatime,subvol=/deploy/target" \
	/dev/mapper/root /mnt/root/deploy/image-a

# TODO: Verify the downloaded files.
info "Download a stage 3 tarball."
arch="amd64"
mirror="http://ftp.kaist.ac.kr/gentoo/releases"
wget --recursive --no-parent --no-directories \
	--directory-prefix="download" \
	--accept="stage3-${arch}-hardened-openrc-*" \
	"${mirror}/${arch}/autobuilds/current-stage3-${arch}-openrc/"

install_root="/mnt/root/deploy/image-a"

info "Extract the stage 3 tarball into ${install_root}."
find download -iname "stage3-*.tar.xz" -exec tar \
	--directory="${install_root}" \
	--extract --preserve-permissions --file={} \
	--xattrs-include='*.*' --numeric-owner \;

info "Mount pseudo filesystems in the installation."
mount-pseudofs "${install_root}"

chroot_cleanup() {
	info "Clean up installation artiparcts."
	rm --recursive /config
}

chroot_main() {
	info "Mount an efi partition."
	mount "/dev/${partition_uefi}" /boot

	info "Generate the fstab into the installation."
	PARTUUID_UEFI=$(blkid -o value -s PARTUUID "/dev/${partition_uefi}") \
	PARTUUID_SWAP=$(blkid -o value -s PARTUUID "/dev/${partition_swap}") \
	PARTUUID_ROOT=$(blkid -o value -s PARTUUID "/dev/${partition_root}") \
		envsubst < /config/etc/fstab.tmpl > /etc/fstab

	if [ -d /etc/portage/package.use ]
	then
		info "Make the Portage package.use a single file."
		rm --recursive /etc/portage/package.use
		touch /etc/portage/package.use
	fi

	info "Configure the Portage make.conf file."
	install --mode="600" /config/etc/portage/make.conf /etc/portage/make.conf
	echo "MAKEOPTS=\"-j$(nproc)\"" >> /etc/portage/make.conf

	info "Configure the Portage ebuild repositories."
	mkdir --parents /etc/portage/repos.conf
	cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf
	emerge-webrsync

	info "Install system management tools."
	emerge app-portage/gentoolkit app-portage/mirrorselect sys-fs/btrfs-progs

	info "Set the system-wide USE flags."
	euse --enable elogind X bluetooth networkmanager dbus
	euse --disable systemd

	info "Configure Portage mirrors."
	mirrorselect --interactive

	info "Choose a Portage profile."
	eselect profile list
	read -rp "Select a Portage profile: " profile
	eselect profile set "${profile}"

	info "Update @world Portage set."
	emerge --update --deep --newuse @world

	info "Set the timezone to Asia/Seoul."
	echo "Asia/Seoul" > /etc/timezone
	emerge --config sys-libs/timezone-data

	info "Generate system locales."
	nano -w /etc/locale.gen
	locale-gen

	info "Configure system locales."
	eselect locale list
	read -rp "Select a locale: " locale
	eselect locale set "${locale}"

	info "Reload the environment."
	env-update
	source /etc/profile

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
	echo "sys-kernel/linux-firmware linux-fw-redistributable no-source-code" \
		>> /etc/portage/package.license
	emerge sys-kernel/linux-firmware

	info "Install the linux kernel sources."
	emerge sys-kernel/gentoo-sources

	# /usr/src/linux symlink refers to the source tree corresponding to the
	# currently running kernel.
	info "Create a symlink /usr/src/linux."
	eselect kernel list
	read -rp "Select a linux kernel to use: " kernel
	eselect kernel set "${kernel}"

	make="make --directory=/usr/src/linux --jobs=$(nproc)"

	info "Configure the linux kernel."
	${make} defconfig
	${make} menuconfig

	info "Compile and install the linux kernel."
	${make}
	${make} modules_install
	# This will copy the kernel image into /boot together with the System.map
	# file and the kernel configuration file.
	${make} install

	info "Install packages to build an initramfs."
	emerge sys-fs/cryptsetup app-shells/fzf
	emerge --autounmask --autounmask-continue app-crypt/tpm2-tools

	info "Build and install an initramfs."
	emerge-initramfs

	info "Set the hostname."
	read -rp "Enter the hostname: " hostname
	sed -i "s/localhost/${hostname}/g" /etc/conf.d/hostname /etc/hosts

	info "Enable the elogind service."
	rc-update add elogind boot

	info "Install system daemons."
	emerge sys-process/fcron net-misc/chrony net-misc/networkmanager app-admin/rsyslog

	info "Register system daemons to openrc runlevels."
	rc-update add fcron default
	rc-update add chronyd default
	rc-update add NetworkManager default
	rc-update add rsyslog default

	info "Install system packages."
	emerge app-admin/doas \
		&& install --mode="600" config/etc/doas.conf /etc/doas.conf
	echo "app-admin/logrotate cron" >> /etc/portage/package.use \
		&& emerge app-admin/logrotate

	info "Install GRUB2 bootloader."
	emerge sys-boot/grub
	grub-install --target="x86_64-efi" --efi-directory="/boot" --removable
	echo "GRUB_CMDLINE_LINUX=\"root=PARTUUID=$(blkid -o value -s PARTUUID /dev/"${partition_root}")\"" \
		>> /etc/default/grub
	grub-mkconfig --output="/boot/grub/grub.cfg"

	info "Create a default user."
	read -rp "Enter an user name: " user
	useradd --create-home --groups="users,wheel" --shell="/bin/bash" "${user}"
	passwd "${user}"
	install --mode="644" /config/home/user/dot-profile "/home/${user}/.profile"

	info "Install XOrg server."
	emerge x11-base/xorg-server
	env-update
	source /etc/profile
}

info "Configure DNS of the installation."
cp --dereference /etc/resolv.conf "${install_root}/etc/resolv.conf"

info "Set the initramfs source directory in the installation."
find initramfs -mindepth 1 -maxdepth 1 \
	-exec cp --verbose --preserve --recursive {} "${install_root}/usr/src/initramfs" \;

info "Copy config files into the installation."
cp --verbose --recursive config "${install_root}"

info "Install my scripts into the installation."
find -L tools -mindepth 1 -maxdepth 1 \
	-exec cp --verbose --recursive {} "${install_root}/usr/local/bin/" \;

info "chroot into ${install_root} and execute chroot_main()."
chroot "${install_root}" /bin/bash -c "
	set -o errexit -o nounset -o noglob -o pipefail
	this_script=${this_script}
	root_storage=${root_storage}
	partition_uefi=${partition_uefi}
	partition_swap=${partition_swap}
	partition_root=${partition_root}
	$(declare -f info)
	$(declare -f error)
	$(declare -f chroot_cleanup)
	$(declare -f chroot_main)
	chroot_main
	chroot_cleanup
"
