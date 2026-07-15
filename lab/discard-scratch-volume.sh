#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <volume-id> <expected-namespace-uuid>" >&2
    exit 2
fi

volid=$1
expected_uuid=$2
expected_path="/dev/disk/by-id/nvme-uuid.$expected_uuid"

if [[ ${ALLOW_DESTRUCTIVE_DISCARD:-} != yes ]]; then
    echo "refusing destructive discard: set ALLOW_DESTRUCTIVE_DISCARD=yes" >&2
    exit 1
fi

if [[ $volid != *":vm-"*"-disk-"* ]]; then
    echo "refusing volume with an unexpected name: $volid" >&2
    exit 1
fi

vmid=${volid#*:vm-}
vmid=${vmid%%-disk-*}
if qm config "$vmid" >/dev/null 2>&1; then
    echo "refusing volume owned by an existing VM: $vmid" >&2
    exit 1
fi

device=$(pvesm path "$volid")
if [[ $device != "$expected_path" ]]; then
    echo "refusing UUID mismatch: expected $expected_path, got $device" >&2
    exit 1
fi
if [[ ! -b $device ]]; then
    echo "refusing non-block device: $device" >&2
    exit 1
fi

echo "discarding scratch volume $volid"
echo "stable path: $device"
echo "kernel path: $(readlink -f "$device")"
blkdiscard --verbose "$device"
