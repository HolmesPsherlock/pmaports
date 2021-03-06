#!/bin/sh
# This file will be in /init_functions.sh inside the initramfs.
IP=172.16.42.1

# Redirect stdout and stderr to logfile
setup_log() {
	# Bail out if PMOS_NO_OUTPUT_REDIRECT is set
	echo "### postmarketOS initramfs ###"
	grep -q PMOS_NO_OUTPUT_REDIRECT /proc/cmdline && return

	# Print a message about what is going on to the normal output
	echo "NOTE: All output from the initramfs gets redirected to:"
	echo "/pmOS_init.log"
	echo "If you want to disable this behavior (e.g. because you're"
	echo "debugging over serial), please add this to your kernel"
	echo "command line: PMOS_NO_OUTPUT_REDIRECT"

	# Start redirect, print the first line again
	exec >/pmOS_init.log 2>&1
	echo "### postmarketOS initramfs ###"
}

mount_proc_sys_dev() {
	# mdev
	mount -t proc -o nodev,noexec,nosuid proc /proc || echo "Couldn't mount /proc"
	mount -t sysfs -o nodev,noexec,nosuid sysfs /sys || echo "Couldn't mount /sys"

	mkdir /config
	mount -t configfs -o nodev,noexec,nosuid configfs /config

	# /dev/pts (needed for telnet)
	mkdir -p /dev/pts
	mount -t devpts devpts /dev/pts

	# /run (needed for cryptsetup)
	mkdir /run
}

setup_firmware_path() {
	# Add the postmarketOS-specific path to the firmware search paths.
	# This should be sufficient on kernel 3.10+, before that we need
	# the kernel calling udev (and in our case /usr/lib/firmwareload.sh)
	# to load the firmware for the kernel.
	echo "Configuring kernel firmware image search path"
	SYS=/sys/module/firmware_class/parameters/path
	if ! [ -e "$SYS" ]; then
		echo "Kernel does not support setting the firmware image search path. Skipping."
		return
	fi
	# shellcheck disable=SC2039
	echo -n /lib/firmware/postmarketos >$SYS
}

setup_mdev() {
	echo /sbin/mdev >/proc/sys/kernel/hotplug
	mdev -s
}

mount_subpartitions() {
	# Do not create subpartition mappings if pmOS_boot
	# already exists (e.g. installed on an sdcard)
	blkid |grep -q "pmOS_boot"  && return
	attempt_count=0
	echo "Trying to mount subpartitions for 10 seconds..."
	while [ -z "$(find_boot_partition)" ]; do
		partitions="$(grep -v "loop\|ram" < /proc/diskstats |\
			sed 's/\(\s\+[0-9]\+\)\+\s\+//;s/ .*//;s/^/\/dev\//')"
		echo "$partitions" | while read -r partition; do
			case "$(kpartx -l "$partition" 2>/dev/null | wc -l)" in
				2)
					echo "Mount subpartitions of $partition"
					kpartx -afs "$partition"
					# Ensure that this was the *correct* subpartition
					# Some devices have mmc partitions that appear to have
					# subpartitions, but aren't our subpartition.
					if blkid | grep -q "pmOS_boot"; then
						break
					fi
					kpartx -d "$partition"
					continue
					;;
				*)
					continue
					;;
			esac
		done
		attempt_count=$(( attempt_count + 1 ));
		if [ "$attempt_count" -gt "100" ]; then
			echo "ERROR: failed to mount subpartitions!"
			return;
		fi
		sleep 0.1;
	done
}

find_root_partition() {
	# The partition layout is one of the following:
	# a) boot, root partitions on sdcard
	# b) boot, root partition on the "system" partition (which has its
	#    own partition header! so we have partitions on partitions!)
	#
	# mount_subpartitions() must get executed before calling
	# find_root_partition(), so partitions from b) also get found.

	# Short circuit all autodetection logic if pmos_root= is supplied
	# on the kernel cmdline
	# shellcheck disable=SC2013
	for x in $(cat /proc/cmdline); do
		[ "$x" = "${x#pmos_root=}" ] && continue
		DEVICE="${x#pmos_root=}"
	done

	# Try partitions in /dev/mapper and /dev/dm-* first
	if [ -z "$DEVICE" ]; then
		for id in pmOS_root crypto_LUKS; do
			for path in /dev/mapper /dev/dm; do
				DEVICE="$(blkid | grep "$path" | grep "$id" \
					| cut -d ":" -f 1 | head -n 1)"
				[ -z "$DEVICE" ] || break 2
			done
		done
	fi

	# Then try all devices
	if [ -z "$DEVICE" ]; then
		for id in pmOS_root crypto_LUKS; do
			DEVICE="$(blkid | grep "$id" | cut -d ":" -f 1 \
				| head -n 1)"
			[ -z "$DEVICE" ] || break
		done
	fi
	echo "$DEVICE"
}

find_boot_partition() {
	# shellcheck disable=SC2013
	for x in $(cat /proc/cmdline); do
		[ "$x" = "${x#pmos_boot=}" ] && continue
		echo "${x#pmos_boot=}"
		return
	done
	findfs LABEL="pmOS_boot"
}

mount_boot_partition() {
	partition=$(find_boot_partition)
	if [ -z "$partition" ]; then
		echo "ERROR: boot partition not found!"
		show_splash /splash-noboot.ppm.gz
		loop_forever
	fi
	echo "Mount boot partition ($partition)"
	mount -r "$partition" /boot
}

# $1: initramfs-extra path
extract_initramfs_extra() {
	initramfs_extra="$1"
	if [ ! -e "$initramfs_extra" ]; then
		echo "ERROR: initramfs-extra not found!"
		show_splash /splash-noinitramfsextra.ppm.gz
		loop_forever
	fi
	echo "Extract $initramfs_extra"
	gzip -d -c "$initramfs_extra" | cpio -i
}

wait_root_partition() {
	while [ -z "$(find_root_partition)" ]; do
		show_splash /splash-norootfs.ppm.gz
		echo "Could not find the rootfs."
		echo "Maybe you need to insert the sdcard, if your device has"
		echo "any? Trying again in one second..."
		sleep 1
	done
}

resize_root_partition() {
	partition=$(find_root_partition)
	# Only resize the partition if it's inside the device-mapper, which means
	# that the partition is stored as a subpartition inside another one.
	# In this case we want to resize it to use all the unused space of the
	# external partition.
	if [ -z "${partition##"/dev/mapper/"*}" ]; then
		# Get physical device
		partition_dev=$(dmsetup deps -o devname "$partition" | \
			awk -F "[()]" '{print "/dev/"$2}')
		# Check if there is unallocated space at the end of the device
		if parted -s "$partition_dev" print free | tail -n2 | \
			head -n1 | grep -qi "free space"; then
			echo "Resize root partition ($partition)"
			# unmount subpartition, resize and remount it
			kpartx -d "$partition"
			parted -s "$partition_dev" resizepart 2 100%
			kpartx -afs "$partition_dev"
		fi
	fi
	# Resize the root partition (non-subpartitions). Usually we do not want this,
	# except for QEMU devices (where PMOS_FORCE_PARTITION_RESIZE gets passed as
	# kernel parameter).
	if grep -q PMOS_FORCE_PARTITION_RESIZE /proc/cmdline; then
		echo "Resize root partition ($partition)"
		parted -s "$(echo "$partition" | sed -E 's/p?2$//')" resizepart 2 100%
		partprobe
	fi
}

unlock_root_partition() {
	partition="$(find_root_partition)"
	if cryptsetup isLuks "$partition"; then
		until cryptsetup status root | grep -qwi active; do
			start_onscreen_keyboard
		done
		# Show again the loading splashscreen
		show_splash /splash-loading.ppm.gz
	fi
}

resize_root_filesystem() {
	partition="$(find_root_partition)"
	touch /etc/mtab # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=673323
	echo "Check/repair root filesystem ($partition)"
	e2fsck -y "$partition"
	echo "Resize root filesystem ($partition)"
	resize2fs -f "$partition"
}

mount_root_partition() {
	partition="$(find_root_partition)"
	echo "Mount root partition ($partition)"
	mount -t ext4 -o ro "$partition" /sysroot
	if ! [ -e /sysroot/usr ]; then
		echo "ERROR: unable to mount root partition!"
		show_splash /splash-mounterror.ppm.gz
		loop_forever
	fi
}

setup_usb_network_android() {
	# Only run, when we have the android usb driver
	SYS=/sys/class/android_usb/android0
	if ! [ -e "$SYS" ]; then
		echo "  /sys/class/android_usb does not exist, skipping android_usb"
		return
	fi

	echo "  Setting up an USB gadget through android_usb"

	usb_idVendor="$(echo "${deviceinfo_usb_idVendor:-0x18D1}" | sed "s/0x//g")"	# default: Google Inc.
	usb_idProduct="$(echo "${deviceinfo_usb_idProduct:-0xD001}" | sed "s/0x//g")"	# default: Nexus 4 (fastboot)

	# Do the setup
	echo "0" >"$SYS/enable"
	echo "$usb_idVendor" >"$SYS/idVendor"
	echo "$usb_idProduct" >"$SYS/idProduct"
	echo "rndis" >"$SYS/functions"
	echo "1" >"$SYS/enable"
}

setup_usb_network_configfs() {
	# See: https://www.kernel.org/doc/Documentation/usb/gadget_configfs.txt
	CONFIGFS=/config/usb_gadget

	if ! [ -e "$CONFIGFS" ]; then
		echo "  /config/usb_gadget does not exist, skipping configfs usb gadget"
		return
	fi

	# Default values for USB-related deviceinfo variables
	usb_idVendor="${deviceinfo_usb_idVendor:-0x18D1}"   # default: Google Inc.
	usb_idProduct="${deviceinfo_usb_idProduct:-0xD001}" # default: Nexus 4 (fastboot)
	usb_serialnumber="${deviceinfo_usb_serialnumber:-postmarketOS}"
	usb_rndis_function="${deviceinfo_usb_rndis_function:-rndis.usb0}"

	echo "  Setting up an USB gadget through configfs"
	# Create an usb gadet configuration
	mkdir $CONFIGFS/g1 || echo "  Couldn't create $CONFIGFS/g1"
	echo "$usb_idVendor"  > "$CONFIGFS/g1/idVendor"
	echo "$usb_idProduct" > "$CONFIGFS/g1/idProduct"

	# Create english (0x409) strings
	mkdir $CONFIGFS/g1/strings/0x409 || echo "  Couldn't create $CONFIGFS/g1/strings/0x409"

	# shellcheck disable=SC2154
	echo "$deviceinfo_manufacturer" > "$CONFIGFS/g1/strings/0x409/manufacturer"
	echo "$usb_serialnumber"        > "$CONFIGFS/g1/strings/0x409/serialnumber"
	# shellcheck disable=SC2154
	echo "$deviceinfo_name"         > "$CONFIGFS/g1/strings/0x409/product"

	# Create rndis function. The function can be named differently in downstream kernels.
	mkdir $CONFIGFS/g1/functions/"$usb_rndis_function" \
		|| echo "  Couldn't create $CONFIGFS/g1/functions/$usb_rndis_function"

	# Create configuration instance for the gadget
	mkdir $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1"
	mkdir $CONFIGFS/g1/configs/c.1/strings/0x409 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1/strings/0x409"
	echo "rndis" > $CONFIGFS/g1/configs/c.1/strings/0x409/configuration \
		|| echo "  Couldn't write configration name"

	# Link the rndis instance to the configuration
	ln -s $CONFIGFS/g1/functions/"$usb_rndis_function" $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't symlink $usb_rndis_function"

	# Check if there's an USB Device Controller
	if [ -z "$(ls /sys/class/udc)" ]; then
		echo "  No USB Device Controller available"
		return
	fi

	# Link the gadget instance to an USB Device Controller. This activates the gadget.
	# See also: https://github.com/postmarketOS/pmbootstrap/issues/338
	# shellcheck disable=SC2005
	echo "$(ls /sys/class/udc)" > $CONFIGFS/g1/UDC || echo "  Couldn't write UDC"
}

setup_usb_network() {
	# Only run once
	_marker="/tmp/_setup_usb_network"
	[ -e "$_marker" ] && return
	touch "$_marker"
	echo "Setup usb network"
	# Run all usb network setup functions (add more below!)
	setup_usb_network_android
	setup_usb_network_configfs
}

start_udhcpd() {
	# Only run once
	[ -e /etc/udhcpd.conf ] && return

	# Skip if disabled
	# shellcheck disable=SC2154
	if [ "$deviceinfo_disable_dhcpd" = "true" ]; then
		echo "NOTE: start of dhcpd is disabled (deviceinfo_disable_dhcpd)"
		touch /etc/udhcpcd.conf
		return
	fi

	echo "Starting udhcpd"
	# Get usb interface
	INTERFACE=""
	ifconfig rndis0 "$IP" 2>/dev/null && INTERFACE=rndis0
	if [ -z $INTERFACE ]; then
		ifconfig usb0 "$IP" 2>/dev/null && INTERFACE=usb0
	fi
	if [ -z $INTERFACE ]; then
		ifconfig eth0 "$IP" 2>/dev/null && INTERFACE=eth0
	fi

	if [ -z $INTERFACE ]; then
		echo "  Could not find an interface to run a dhcp server on"
		echo "  Interfaces:"
		ip link
		return
	fi

	echo "  Using interface $INTERFACE"

	# Create /etc/udhcpd.conf
	{
		echo "start 172.16.42.2"
		echo "end 172.16.42.2"
		echo "auto_time 0"
		echo "decline_time 0"
		echo "conflict_time 0"
		echo "lease_file /var/udhcpd.leases"
		echo "interface $INTERFACE"
		echo "option subnet 255.255.255.0"
	} >/etc/udhcpd.conf

	echo "  Start the dhcpcd daemon (forks into background)"
	udhcpd
}

setup_directfb_tslib() {
	# Set up directfb and tslib
	# Note: linux_input module is disabled since it will try to take over
	# the touchscreen device from tslib (e.g. on the N900)
	export DFBARGS="system=fbdev,no-cursor,disable-module=linux_input"
	# shellcheck disable=SC2154
	if [ -n "$deviceinfo_dev_touchscreen" ]; then
		export TSLIB_TSDEVICE="$deviceinfo_dev_touchscreen"
	fi
}

start_onscreen_keyboard() {
	setup_directfb_tslib
	osk-sdl -n root -d "$partition" -c /etc/osk.conf -v > /osk-sdl.log 2>&1
	unset DFBARGS
	unset TSLIB_TSDEVICE
}

start_charging_mode() {
	# Check cmdline for charging mode
	chargingmodes="
		androidboot.mode=charger
		lpm_boot=1
		androidboot.huawei_type=oem_rtc
		startup=0x00010004
		lpcharge=1
		androidboot.bootchg=true
	"
	# shellcheck disable=SC2086
	grep -Eq "$(echo $chargingmodes | tr ' ' '|')" /proc/cmdline || return
	setup_directfb_tslib
	# Get the font from osk-sdl config
	fontpath=$(awk '/^keyboard-font/{print $3}' /etc/osk.conf)
	# Set up triggerhappy config
	{
		echo "KEY_POWER 1 pgrep -x charging-sdl || charging-sdl -pcf $fontpath"
	} >/etc/triggerhappy.conf
	# Start it once and then start triggerhappy
	(
		charging-sdl -pcf "$fontpath" \
			|| show_splash /splash-charging-error.ppm.gz
	) &
	thd --deviceglob /dev/input/event* --triggers /etc/triggerhappy.conf
}

# $1: path to ppm.gz file
show_splash() {
	# Skip for non-framebuffer devices
	# shellcheck disable=SC2154
	if [ "$deviceinfo_no_framebuffer" = "true" ]; then
		echo "NOTE: Skipping framebuffer splashscreen (deviceinfo_no_framebuffer)"
		return
	fi

	gzip -c -d "$1" >/tmp/splash.ppm
	fbsplash -s /tmp/splash.ppm
}

set_framebuffer_mode() {
	[ -e "/sys/class/graphics/fb0/modes" ] || return
	[ -z "$(cat /sys/class/graphics/fb0/mode)" ] || return

	_mode="$(cat /sys/class/graphics/fb0/modes)"
	echo "Setting framebuffer mode to: $_mode"
	echo "$_mode" > /sys/class/graphics/fb0/mode
}

setup_framebuffer() {
	# Skip for non-framebuffer devices
	# shellcheck disable=SC2154
	if [ "$deviceinfo_no_framebuffer" = "true" ]; then
		echo "NOTE: Skipping framebuffer setup (deviceinfo_no_framebuffer)"
		return
	fi

	# Wait for /dev/fb0
	echo "NOTE: Waiting 10 seconds for the framebuffer /dev/fb0."
	echo "If your device does not have a framebuffer, disable this with:"
	echo "no_framebuffer=true in <https://postmarketos.org/deviceinfo>"
	for _ in $(seq 1 100); do
		[ -e "/dev/fb0" ] && break
		sleep 0.1
	done
	if ! [ -e "/dev/fb0" ]; then
		echo "ERROR: /dev/fb0 did not appear!"
		return
	fi

	set_framebuffer_mode
}

setup_bootchart2() {
	if grep -q PMOS_BOOTCHART2 /proc/cmdline; then
		if [ -f "/sysroot/sbin/bootchartd" ]; then
			# shellcheck disable=SC2034
			init="/sbin/bootchartd"
			echo "remounting /sysroot as rw for /sbin/bootchartd"
			mount -o remount, rw /sysroot

			# /dev/null may not exist at the first boot after
			# the root filesystem has been created.
			[ -c /sysroot/dev/null ] && return
			echo "creating /sysroot/dev/null for /sbin/bootchartd"
			mknod -m 666 "/sysroot/dev/null" c 1 3
		else
			echo "WARNING: bootchart2 is not installed."
		fi
	fi
}

loop_forever() {
	while true; do
		sleep 1
	done
}
