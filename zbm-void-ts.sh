#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Error: this script must be run as root" 
   exit 1
fi

dmesg | grep -iq efivars || (echo "Error: EFI not supported on this device." && exit)

echo "Enter hostname: "
read _HOSTNAME

if [[ -z "${_HOSTNAME}" ]]; then
    echo "Error: hostname cannot be empty"
    exit 1
fi

echo "Enter new root password: "
read -s _ROOT_PASSWORD

if [[ -z "${_ROOT_PASSWORD}" ]]; then
    echo "Error: password cannot be empty"
    exit 1
fi

echo "Paste Tailscale Auth Key: "
read -s _TS_AUTH_KEY

if [[ -z "${_TS_AUTH_KEY}" ]]; then
    echo "Error: Tailscale auth key cannot be empty"
    exit 1
fi

read -p "Enable Tailscale SSH? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    export _TS_SSH=" --ssh "
else
    export _TS_SSH=""
fi

read -p "Accept Tailscale DNS? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    export _TS_DNS=" --accept-dns "
else
    export _TS_DNS=""
fi

read -p "Set as Tailscale Exit Node? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    export _TS_EXIT_NODE=" --advertise-exit-node "
else
    export _TS_EXIT_NODE=""
fi

read -p "WARNING: installation will overwrite existing device drive and all existing data will be lost! Proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting. No changes have been made to your device."
    exit
fi

echo
echo "Setting up ZFS Pool..."
echo

source /etc/os-release
export ID

zgenhostid -f

export DISK=$(lsblk -e8 -o NAME,TYPE,SIZE | grep 'disk' | awk '{printf $1;}')

if [[ $DISK == "nvme"* ]]; then
    export BOOT_DISK="/dev/${DISK}"
    export BOOT_PART="1"
    export BOOT_DEVICE="${BOOT_DISK}p${BOOT_PART}"
    export POOL_DISK="/dev/${DISK}"
    export POOL_PART="2"
    export POOL_DEVICE="${POOL_DISK}p${POOL_PART}"
else
    export BOOT_DISK="/dev/${DISK}"
    export BOOT_PART="1"
    export BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
    export POOL_DISK="/dev/${DISK}"
    export POOL_PART="2"
    export POOL_DEVICE="${POOL_DISK}${POOL_PART}"
fi

zpool labelclear -f "$POOL_DISK"

wipefs -a "$POOL_DISK"
wipefs -a "$BOOT_DISK"

sgdisk --zap-all "$POOL_DISK"
sgdisk --zap-all "$BOOT_DISK"

sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$BOOT_DISK"

sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$POOL_DISK"

zpool create -f -o ashift=12 \
 -O compression=lz4 \
 -O acltype=posixacl \
 -O xattr=sa \
 -O relatime=on \
 -o autotrim=on \
 -m none zroot "$POOL_DEVICE"

zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
zfs create -o mountpoint=/home zroot/home

zpool set bootfs=zroot/ROOT/${ID} zroot

zpool export zroot
zpool import -N -R /mnt zroot
zfs mount zroot/ROOT/${ID}
zfs mount zroot/home

test $(mount | grep -E 'zroot/ROOT/void on /mnt type zfs|zroot/home on /mnt/home type zfs' | wc -l) -ne 2 && (echo "Error: zfs mount issue" && exit 1)

udevadm trigger

echo
echo "Downloading Void Linux..."
echo

# https://xmirror.voidlinux.org/

export _VOID_MIRROR=https://mirrors.servercentral.com/voidlinux/current

# ...another fast option is https://mirrors.cicku.me/voidlinux/current

xbps-install -yu xbps
echo y | xbps-install -Sy -R ${_VOID_MIRROR} -r /mnt base-system

cp /etc/hostid /mnt/etc
cp /etc/resolv.conf /mnt/etc

echo
echo "Configuring chroot..."
echo

xchroot /mnt /usr/bin/bash <<EOT

echo "/usr/bin/bash" | chsh

(echo "${_ROOT_PASSWORD}"; echo "${_ROOT_PASSWORD}") | passwd

hostname ${_HOSTNAME}

cat << EOF >> /etc/rc.conf
KEYMAP="us"
HARDWARECLOCK="UTC"
EOF
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

cat << EOF >> /etc/default/libc-locales
en_US.UTF-8 UTF-8
en_US ISO-8859-1
EOF
xbps-reconfigure -f glibc-locales

echo
echo "Installing ZFS (this will take a while)..."
echo

cat << EOF > /etc/dracut.conf.d/zol.conf
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF

xbps-install -Sy zfs

echo
echo "Configuring ZFS..."
echo

zfs set org.zfsbootmenu:commandline="quiet net.ifnames=0 pci=nommconf" zroot/ROOT

mkfs.vfat -F32 "${BOOT_DEVICE}"

cat << EOF >> /etc/fstab
${BOOT_DEVICE} /boot/efi vfat defaults 0 0
EOF

mkdir -p /boot/efi
mount /boot/efi

echo
echo "Installing ZFSBootMenu..."
echo

xbps-install -Sy vim nano curl efibootmgr

mkdir -p /boot/efi/EFI/ZBM
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
efibootmgr -c -d "${BOOT_DISK}" -p "${BOOT_PART}" -L "ZFSBootMenu" -l "\EFI\ZBM\VMLINUZ.EFI"

echo
echo "Enabling DHCP..."
echo

cat << EOF >> /etc/rc.local
ip link set eth0 up && sleep 10 && dhcpcd
EOF

echo
echo "Setting up Tailscale..."
echo

if [[ -n "${_TS_EXIT_NODE}" ]]; then
    test -d /etc/sysctl.d && (echo -e "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale.conf && sysctl -p /etc/sysctl.d/99-tailscale.conf) || (echo -e "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf && sysctl -p /etc/sysctl.conf)
fi

export TS_DEBUG_FIREWALL_MODE=nftables

xbps-install -Sy tailscale

cat << EOF >> /etc/rc.local
export TS_DEBUG_FIREWALL_MODE=nftables
nohup tailscaled >/dev/null 2>&1 &
EOF

echo
echo "Registering Tailscale node..."
echo

nohup tailscaled >/dev/null 2>&1 &

sleep 4

nohup tailscale up --advertise-tags=tag:server ${_TS_SSH} ${_TS_DNS} ${_TS_EXIT_NODE} --auth-key=${_TS_AUTH_KEY} >/dev/null 2>&1 &

sleep 4

pkill -f tailscale

sleep 1

pkill -f tailscaled

sleep 1

EOT

echo
echo "Finalizing..."
echo

umount -n -R /mnt

zpool export zroot

echo
read -p "Remove bootable thumb drive, then press ENTER to reboot into your new ZFSBootMenu device"

reboot

exit 0
