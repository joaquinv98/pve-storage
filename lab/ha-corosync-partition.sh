#!/usr/bin/env bash
set -euo pipefail

action="${1:?usage: $0 apply|remove PEER_IP QDEVICE_IP [TAG]}"
peer_ip="${2:?usage: $0 apply|remove PEER_IP QDEVICE_IP [TAG]}"
qdevice_ip="${3:?usage: $0 apply|remove PEER_IP QDEVICE_IP [TAG]}"
tag="${4:-pve-nvme-ha-partition}"

rules=(
    "OUTPUT -p udp -d $peer_ip -m comment --comment $tag -j DROP"
    "INPUT -p udp -s $peer_ip -m comment --comment $tag -j DROP"
    "OUTPUT -p tcp -d $qdevice_ip --dport 5403 -m comment --comment $tag -j DROP"
    "INPUT -p tcp -s $qdevice_ip --sport 5403 -m comment --comment $tag -j DROP"
)

case "$action" in
    apply)
        for rule in "${rules[@]}"; do
            # Intentional word splitting: every token is a fixed rule argument or
            # a caller-supplied IP/tag validated by iptables itself.
            # shellcheck disable=SC2086
            iptables -C $rule 2>/dev/null || iptables -I $rule
        done
        ;;
    remove)
        for rule in "${rules[@]}"; do
            # shellcheck disable=SC2086
            while iptables -C $rule 2>/dev/null; do
                # shellcheck disable=SC2086
                iptables -D $rule
            done
        done
        ;;
    *)
        echo "invalid action '$action'" >&2
        exit 2
        ;;
esac
