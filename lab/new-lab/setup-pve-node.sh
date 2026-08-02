#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 HOSTNAME MANAGEMENT_IP" >&2
    exit 2
fi

node_name="$1"
management_ip="$2"
export DEBIAN_FRONTEND=noninteractive

hostnamectl set-hostname "$node_name"
install -m 0644 /tmp/zfsnvme-hosts /etc/hosts
install -m 0644 /tmp/99-zfsnvme-hosts.cfg /etc/cloud/cloud.cfg.d/99-zfsnvme-hosts.cfg
sed -i -E 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf
getent ahostsv4 "$node_name" | grep -F "$management_ip" >/dev/null

install -m 0600 /tmp/zfsnvme-data.yaml /etc/netplan/60-zfsnvme-data.yaml
netplan apply

for enterprise_repo in \
    /etc/apt/sources.list.d/pve-enterprise.sources \
    /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$enterprise_repo" ]]; then
        mv "$enterprise_repo" "$enterprise_repo.disabled"
    fi
done

printf '%s\n' \
    'grub-pc grub-pc/install_devices multiselect /dev/sda' \
    'grub-pc grub-pc/install_devices_disks_changed multiselect /dev/sda' \
    'grub-pc grub-pc/install_devices_empty boolean false' | debconf-set-selections

apt-get update
apt-get -y full-upgrade
apt-get install -y ca-certificates wget gnupg
wget -q https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg
install -m 0644 /tmp/proxmox.sources /etc/apt/sources.list.d/proxmox.sources
apt-get update

printf '%s\n' \
    'postfix postfix/mailname string lab.neatech.ar' \
    'postfix postfix/main_mailer_type select Local only' | debconf-set-selections

apt-get install -y \
    proxmox-default-kernel proxmox-ve pve-edk2-firmware postfix open-iscsi chrony \
    nvme-cli fio jq git build-essential devscripts debhelper lintian perl-doc

install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
IFS= read -r public_key </tmp/zfsnvme-lab.pub
grep -qxF "$public_key" /root/.ssh/authorized_keys || printf '%s\n' "$public_key" >>/root/.ssh/authorized_keys

install -d -m 0755 /etc/nvme
[[ -s /etc/nvme/hostnqn ]] || nvme gen-hostnqn >/etc/nvme/hostnqn
if [[ ! -s /etc/nvme/hostid ]]; then
    IFS= read -r hostid </proc/sys/kernel/random/uuid
    printf '%s\n' "$hostid" >/etc/nvme/hostid
fi

printf '%s\n' nvme_tcp >/etc/modules-load.d/zfsnvme-lab.conf
systemctl enable pveproxy pvedaemon pvestatd ssh

if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
    mv /etc/apt/sources.list.d/pve-enterprise.sources \
        /etc/apt/sources.list.d/pve-enterprise.sources.disabled
fi

echo "NODE=$node_name"
pveversion --verbose
ip -br address
echo REBOOT_REQUIRED
