#!/usr/bin/env bash
set -euo pipefail

vmid="${1:?usage: $0 VMID OUTPUT [INTERVAL]}"
output="${2:?usage: $0 VMID OUTPUT [INTERVAL]}"
interval="${3:-0.2}"
pidfile="/run/qemu-server/${vmid}.pid"

while true; do
    timestamp="$(date +%s.%N)"
    state=stopped
    pid=-

    if [[ -r "$pidfile" ]]; then
        pid="$(<"$pidfile")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            state=running
        fi
    fi

    printf '%s\t%s\t%s\n' "$timestamp" "$state" "$pid" >> "$output"
    sleep "$interval"
done
