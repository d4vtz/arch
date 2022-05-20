#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL https://git.io/vAoV8 | bash
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

REPO_URL="https://s3.eu-west-2.amazonaws.com/mdaffin-arch/repo/x86_64"
MIRRORLIST_URL="https://archlinux.org/mirrorlist/?country=GB&protocol=https&use_mirror_status=on"

pacman -Sy --noconfirm pacman-contrib dialog

echo "Updating mirror list"
curl -s "$MIRRORLIST_URL" | \
    sed -e 's/^#Server/Server/' -e '/^#/d' | \
    rankmirrors -n 5 - > /etc/pacman.d/mirrorlist

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + 129 + 1 ))MiB

parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 524MiB \
  set 1 boot on \
  mkpart primary btrfs 524 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

wipefs "${part_boot}"
wipefs "${part_root}"

mkfs.vfat -F32 -n EFI "${part_boot}"
mkfs.btrfs -L Arch "${part_root}"


mount "${part_root}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o x-mount.mkdir,noatime,compress=zstd,space_cache=v2,ssd,discard=async,commit=120,subvol=@ '${part_root}' /mnt
mount -o x-mount.mkdir,noatime,compress=zstd,space_cache=v2,ssd,discard=async,commit=120,subvol=@home '${part_root}' /mnt/home
mount -o x-mount.mkdir,noatime,compress=zstd,space_cache=v2,ssd,discard=async,commit=120,subvol=@var '${part_root}' /mnt/var
mount -o x-mount.mkdir,noatime,compress=zstd,space_cache=v2,ssd,discard=async,commit=120,subvol=@swap '${part_root}' /mnt/swap
mount -o x-mount.mkdir,noatime,compress=zstd,space_cache=v2,ssd,discard=async,commit=120,subvol=@snapshots '${part_root}' /mnt/.snapshots
mount -p x-mount.mkdir '${part_boot}' /mnt/boot

### Install and configure the basic system ###

pacstrap /mnt base base-devel linux linux-headers linux-firmware amd-ucode btrfs-progs nvim grub grub-btrfs efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab

echo "${hostname}" > /mnt/etc/hostname
echo "LANG=es_MX.UTF-8" > /mnt/etc/locale.conf


arch-chroot /mnt useradd -mG wheel "$user"

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-efi=Arch
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

