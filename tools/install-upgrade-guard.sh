#!/bin/sh

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
guard=/usr/local/sbin/pve-zfsnvme-upgrade-guard
apt_conf=/etc/apt/apt.conf.d/99-pve-zfsnvme-upgrade-guard

if [ "${1:-}" = --uninstall ]; then
    rm -f -- "$apt_conf" "$guard"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "run this installer as root" >&2
    exit 1
fi

install -D -m 0755 "$script_dir/pve-zfsnvme-upgrade-guard" "$guard"
install -D -m 0644 "$script_dir/99-pve-zfsnvme-upgrade-guard" "$apt_conf"

echo "installed $guard"
echo "installed $apt_conf"
