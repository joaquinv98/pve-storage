#!/usr/bin/env bash
set -euo pipefail

start_vmid="${1:?start VMID is required}"
count="${2:-8}"
storage="${3:-nvmetcp-lab}"

pids=()
for ((offset = 0; offset < count; offset++)); do
    vmid=$((start_vmid + offset))
    pvesm alloc "$storage" "$vmid" "vm-$vmid-disk-0" 128M \
        >"/tmp/zfsnvme-alloc-$vmid.log" 2>&1 &
    pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done

if ((failed)); then
    for ((offset = 0; offset < count; offset++)); do
        vmid=$((start_vmid + offset))
        printf '%s: ' "$vmid"
        sed -n '1,5p' "/tmp/zfsnvme-alloc-$vmid.log"
    done
    exit 1
fi

printf 'allocated %d volumes beginning at VMID %d\n' "$count" "$start_vmid"
