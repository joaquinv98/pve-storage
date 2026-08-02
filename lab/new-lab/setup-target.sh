#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

hostnamectl set-hostname zfsnvme-target
# A PVE cloud-init ZVOL has a cidata label. Leaving cloud-init discovery active
# on the storage host can make it consume a guest's ZVOL on the next boot.
touch /etc/cloud/cloud-init.disabled
install -m 0600 /tmp/zfsnvme-data.yaml /etc/netplan/60-zfsnvme-data.yaml
netplan apply

apt-get update
apt-get -y full-upgrade
apt-get install -y zfsutils-linux nvme-cli fio jq config-package-dev

modprobe nvmet_tcp
printf '%s\n' nvmet_tcp >/etc/modules-load.d/zfsnvme-target.conf
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
test -d /sys/kernel/config/nvmet/subsystems

install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
IFS= read -r public_key </tmp/zfsnvme-lab.pub
key_blob="${public_key#* }"
key_blob="${key_blob%% *}"
grep -vF "$key_blob" /root/.ssh/authorized_keys >/tmp/zfsnvme-authorized-keys
{
    printf '%s\n' "$public_key"
    cat /tmp/zfsnvme-authorized-keys
} >/root/.ssh/authorized_keys
rm -f /tmp/zfsnvme-authorized-keys

if ! zpool list -H tank >/dev/null 2>&1; then
    test -b /dev/sdb
    test "$(lsblk -dn -o SIZE /dev/sdb | tr -d ' ')" = 32G
    test -z "$(lsblk -dn -o FSTYPE /dev/sdb)"
    zpool create -f -o ashift=12 \
        -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
        tank /dev/sdb
fi

zfs set compression=lz4 tank
zpool set cachefile=/etc/zfs/zpool.cache tank
zpool status tank
ip -br address
