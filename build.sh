#!/bin/bash
#
# Copyright (C) 2013, Attila Sukosd (as@airtame.com)
# License: MIT
#
# The following is a simple raspbian image builder script
# Heavily inspired by ...
#

# Should the build be for production or development? (prod/dev)
build_for="prod"

#####################################
# Settings for the production build #
#####################################
prod_rootfs_size="1024" # in MB
prod_extra_pkgs="iw wireless-tools wpasupplicant"
prod_deploy_scripts=""

######################################
# Settings for the development build #
######################################
dev_rootfs_size="10240" # in MB
dev_extra_pkgs="build-essential git-core htop automake autoconf make m4 yasm"
dev_deploy_scripts=""

####################
# General settings #
####################
hostname="raspi" 
root_passwd="raspberry" # Root password
common_pkgs="openssh-server ntp less vim-nox locales console-common"  # Packages which should be installed in both prod and dev environments
bootsize="64M" # Size of the boot partition
deb_release="wheezy"
rpi_release="raspbian"
deb_mirror="http://archive.raspbian.org/raspbian"
deb_local_mirror="http://localhost:3142/archive.raspbian.org/raspbian"

# Kernel tweaking
kernel_modules_to_load="vchiq snd_bcm2835"
kernel_params="dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait"


####################################################
######## END OF CONFIG, DO NOT EDIT BELOW ##########
####################################################
relative_path=`dirname $0`
absolute_path=`cd ${relative_path}; pwd`
delivery_path=`cd ${absolute_path}/delivery; pwd`
buildenv=`cd ${absolute_path}; mkdir -p images; cd images; pwd`

rootfs="${buildenv}/rootfs"
bootfs="${rootfs}/boot"

if [ ${EUID} -ne 0 ]; then
	echo "This tool much be run as root!";
	exit;
fi;

# Create the block device
function create_image {
	echo "*** Creating the image..."
	device=$1
	if [ ! -b "${device}" ]; then
		echo "Not a block device (${device}), creating an image!"
	else
		echo "Block device writing not supported for your own safety!";
		exit 1;
	fi;
	
	# Create the image name
	today=`date +%d%m%Y`
	mkdir -p ${buildenv}
	image="${buildenv}/rpi_${rpi_release}_${today}_${build_for}.img"	
	
	if [ "${build_for}" == "prod" ]; then
		rootfssize=${prod_rootfs_size};
	else
		rootfssize=${dev_rootfs_size};
	fi;

	# Create a flat file image
	dd if=/dev/zero of=${image} bs=1M count=${rootfssize}
	# Setup the virtual block device
	device=`losetup -f --show ${image}`
	echo "image ${image} created and mounted as ${device}"

	# Partition the image
	fdisk ${device} << EOF
n
p
1

+${bootsize}
t
c
n
p
2


w
EOF
	# Remove the virtual device
	losetup -d ${device}
	
	device=`kpartx -va ${image} | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -n 1`
	device="/dev/mapper/${device}"
	
	bootp=${device}p1
	rootp=${device}p2

	if [ ! -b ${bootp} ]; then
		echo "Something went wrong :-S Can't find boot partition as ${device}1, Quitting!";
		exit 1;
	fi;

	mkfs.vfat ${bootp}
	mkfs.ext4 ${rootp}

}

# After the image has been created, it is now prepared for operations
function prepare_image {
	echo "*** Preparing the image ${rootfs}"
	mkdir -p ${rootfs}
	
	mount ${rootp} ${rootfs}
	mkdir -p ${rootfs}/proc
	mkdir -p ${rootfs}/sys
	mkdir -p ${rootfs}/dev
	mkdir -p ${rootfs}/dev/pts
	mkdir -p ${rootfs}/usr/src/delivery

	mount -t proc proc ${rootfs}/proc
	mount -t sysfs none ${rootfs}/sys
	mount -o bind /dev ${rootfs}/dev
	mount -o bind /dev/pts ${rootfs}/dev/pts
	mount -o bind ${delivery_path} ${rootfs}/usr/src/delivery

	cd ${rootfs}
}

# Bootstrap a minimal distro
function bootstap_image {
	echo "*** Boostraping the image"
	
	cd ${rootfs}
	
	debootstrap --foreign --no-check-gpg --arch armhf ${deb_release} ${rootfs} ${deb_local_mirror}
	cp /usr/bin/qemu-arm-static usr/bin/

	LANG=C chroot ${rootfs} /debootstrap/debootstrap --second-stage	

	mount ${bootp} ${bootfs}
}

# Basic configuration of the image
function config_image {
	echo "*** Configuring the image"

	cd ${rootfs}	
	# Set APT sources list
	echo "deb ${deb_local_mirror} ${deb_release} main contrib non-free" > etc/apt/sources.list

	# Set the boot kernel parameters
	echo ${kernel_params} > boot/cmdline.txt

	# Setup fstab
	echo "proc            /proc           proc    defaults        0       0
/dev/mmcblk0p1  /boot           vfat    defaults        0       0
" > etc/fstab
	
	# Setup the hostname
	echo ${hostname} > etc/hostname

	# Setup the default network interfaces
	echo "auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
" > etc/network/interfaces

	# Setup the modules to load on boot
	for m in ${kernel_modules_to_load}; do
		echo $m >> etc/modules
	done;	

	# Console settings, user settings
	echo "console-common    console-data/keymap/policy      select  Select keymap from full list
console-common  console-data/keymap/full        select  de-latin1-nodeadkeys
" > debconf.set
	echo "#!/bin/bash
debconf-set-selections /debconf.set
rm -f /debconf.set

echo \"root:${root_password}\" |chpasswd	

sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules

rm -f /debconf.sh
" > debconf.sh
	chmod +x debconf
	LANG=C chroot ${rootfs} /debconf.sh
}

# Install wanted packages
function install_pkgs_image {
	echo "*** Installing the user defined packages"

	cd ${rootfs}

        if [ "${build_for}" == "prod" ]; then
                pkgs=${prod_extra_pkgs};
        else
                pkgs=${dev_extra_pkgs};
        fi;

	echo "#!/bin/bash

apt-get update
apt-get -y install ${common_pkgs}
apt-get -y install ${pkgs}

rm -f /installpkgs.sh
" > installpkgs.sh
	
	chmod +x installpkgs.sh
	LANG=C chroot ${rootfs} /installpkgs.sh	
}

# Install raspberry firmware
function install_raspberry_firmware_image {
	echo "*** Installing the raspberry firmware in the image"

	cd ${rootfs}
	echo "#!/bin/bash

apt-get update
apt-get -y install git-core binutils
wget --continue https://raw.github.com/asb/raspi-config/master/raspi-config -O /usr/bin/raspi-config
chmod +x /usr/bin/raspi-config
wget --continue https://raw.github.com/Hexxeh/rpi-update/master/rpi-update -O /usr/bin/rpi-update
chmod +x /usr/bin/rpi-update
mkdir -p /lib/modules/3.6.11+
touch /boot/start.elf
rpi-update

rm -f /rpi.sh
" > rpi.sh
	chmod +x rpi.sh
	LANG=C chroot ${rootfs} /rpi.sh

}

# Instal custom scripts
function install_custom_scripts_image {
	echo "*** Installing the custom scripts in the image"
	
	cd ${rootfs}
	echo "#!/bin/bash

cd /usr/src/delivery
./install.sh
cd

rm -f /custom.sh
" > custom.sh
	chmod +x custom.sh
	LANG=C chroot ${rootfs} /custom.sh
	
}

# Finalize image
function finalize_image {
	echo "*** Finalizing the image"

	echo "deb ${deb_mirror} ${deb_release} main contrib non-free" > etc/apt/sources.list

	# Cleanup script
	echo "#!/bin/bash
	
aptitude update
aptitude clean
apt-get clean

rm -f /cleanup.sh
" > cleanup.sh
	chmod +x cleanup.sh
	LANG=C chroot ${rootfs} /cleanup.sh
	
	cd ${rootfs}
	sync
	echo "Finalized image."
	sleep 10;
}

# Cleanup after install into the image
function cleanup_image {
	echo "*** Cleaning up the image"
	umount -l ${bootp}
	umount -l ${rootfs}/usr/src/delivery
	umount -l ${rootfs}/dev/pts
	umount -l ${rootfs}/dev
	umount -l ${rootfs}/sys
	umount -l ${rootfs}/proc
	
	umount -l ${rootfs}
	umount -l ${rootp}

	kpartx -d ${image}
	echo "Cleaned up."
}

# Trap Ctrl-c so we can quit nicely!
function trap_func {
	echo "SIGINT caught, cleaning up!"
	cleanup_image
	echo "Quitting!"
	exit 255;
}

trap 'trap_func' SIGINT

create_image "$1"
prepare_image

bootstap_image
install_pkgs_image
install_raspberry_firmware_image
install_custom_scripts_image

finalize_image

cleanup_image

echo "Created image: ${image}"
