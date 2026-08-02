#!/usr/bin/env bash
set -euo pipefail

mode="${1:?mode is required: single-a, single-b, short-all, or long-all}"
volume="${2:-nvmetcp-lab:vm-910-disk-0}"
result_root="${RESULT_ROOT:-/root/zfsnvme-results/link-failure}"
iface_a="${IFACE_A:-ens19}"
iface_b="${IFACE_B:-ens20}"
address_a="${ADDRESS_A:-10.90.1.11}"
address_b="${ADDRESS_B:-10.90.2.11}"
result_dir="$result_root/$mode"

mkdir -p "$result_dir"
device="$(pvesm path "$volume")"
[[ -b "$device" ]] || {
    printf 'volume path is not a block device: %s\n' "$device" >&2
    exit 1
}

link_up() {
    ip link set "$1" up
}

link_down() {
    ip link set "$1" down
}

wait_for_live_path() {
    local address="$1"
    for ((attempt = 0; attempt < 90; attempt++)); do
        if nvme list-subsys 2>/dev/null |
            grep -F "traddr=$address" |
            grep -q ' live$'; then
            return 0
        fi
        sleep 1
    done
    printf 'NVMe path %s did not become live\n' "$address" >&2
    return 1
}

cleanup() {
    link_up "$iface_a" 2>/dev/null || true
    link_up "$iface_b" 2>/dev/null || true
}
trap cleanup EXIT
cleanup
wait_for_live_path "$address_a"
wait_for_live_path "$address_b"

if [[ "$mode" == long-all ]]; then
    start_seconds="$(date +%s)"
    set +e
    fio \
        --name=long-all-path-loss \
        --filename="$device" \
        --rw=randwrite \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --time_based=1 \
        --runtime=90 \
        --exitall_on_error=1 \
        --group_reporting=1 \
        --output-format=json \
        --output="$result_dir/fio.json" &
    fio_pid=$!
    set -e

    sleep 5
    link_down "$iface_a"
    link_down "$iface_b"
    printf '%s both-paths-down\n' "$(date --iso-8601=ns)" >"$result_dir/timeline.log"

    failure_observed=0
    for ((attempt = 0; attempt < 45; attempt++)); do
        if ! kill -0 "$fio_pid" 2>/dev/null; then
            failure_observed=1
            break
        fi
        sleep 1
    done

    cleanup
    printf '%s both-paths-up\n' "$(date --iso-8601=ns)" >>"$result_dir/timeline.log"
    wait_for_live_path "$address_a"
    wait_for_live_path "$address_b"

    set +e
    wait "$fio_pid"
    fio_rc=$?
    set -e
    elapsed=$(( $(date +%s) - start_seconds ))
    # fio writes per-I/O error messages before its JSON document. With many
    # simultaneous completions, the opening brace can share the final error
    # line, so isolate the document before passing it to jq.
    json_version_line="$(grep -n -m1 '"fio version"' "$result_dir/fio.json" | cut -d: -f1)"
    json_start_line=$((json_version_line - 1))
    tail -n +"$json_start_line" "$result_dir/fio.json" |
        sed '1s/^[^{]*//' >"$result_dir/fio-clean.json"
    error="$(jq -r '.jobs[0].error' "$result_dir/fio-clean.json")"
    jq -n \
        --argjson failure_observed "$failure_observed" \
        --argjson fio_rc "$fio_rc" \
        --argjson fio_error "$error" \
        --argjson elapsed_seconds "$elapsed" \
        '{failure_observed: $failure_observed, fio_rc: $fio_rc, fio_error: $fio_error, elapsed_seconds: $elapsed_seconds}' \
        >"$result_dir/summary.json"
    cat "$result_dir/summary.json"

    [[ "$failure_observed" == 1 ]]
    ((fio_rc != 0))
    ((error != 0))

    fio \
        --name=post-recovery \
        --filename="$device" \
        --rw=write \
        --bs=128k \
        --size=64M \
        --ioengine=libaio \
        --iodepth=16 \
        --direct=1 \
        --verify=crc32c \
        --do_verify=1 \
        --verify_fatal=1 \
        --output-format=json \
        --output="$result_dir/post-recovery.json"
    [[ "$(jq -r '.jobs[0].error' "$result_dir/post-recovery.json")" == 0 ]]
    exit 0
fi

fio \
    --name="$mode" \
    --filename="$device" \
    --rw=write \
    --bs=128k \
    --size=1G \
    --ioengine=libaio \
    --iodepth=32 \
    --direct=1 \
    --refill_buffers=1 \
    --randrepeat=0 \
    --verify=crc32c \
    --do_verify=1 \
    --verify_fatal=1 \
    --group_reporting=1 \
    --output-format=json \
    --output="$result_dir/fio.json" &
fio_pid=$!

sleep 3
case "$mode" in
    single-a)
        link_down "$iface_a"
        printf '%s path-a-down\n' "$(date --iso-8601=ns)" >"$result_dir/timeline.log"
        sleep 12
        link_up "$iface_a"
        wait_for_live_path "$address_a"
        ;;
    single-b)
        link_down "$iface_b"
        printf '%s path-b-down\n' "$(date --iso-8601=ns)" >"$result_dir/timeline.log"
        sleep 12
        link_up "$iface_b"
        wait_for_live_path "$address_b"
        ;;
    short-all)
        link_down "$iface_a"
        link_down "$iface_b"
        printf '%s both-paths-down\n' "$(date --iso-8601=ns)" >"$result_dir/timeline.log"
        sleep 15
        link_up "$iface_a"
        link_up "$iface_b"
        wait_for_live_path "$address_a"
        wait_for_live_path "$address_b"
        ;;
    *)
        printf 'unsupported mode: %s\n' "$mode" >&2
        exit 2
        ;;
esac

printf '%s paths-restored\n' "$(date --iso-8601=ns)" >>"$result_dir/timeline.log"
wait "$fio_pid"
error="$(jq -r '.jobs[0].error' "$result_dir/fio.json")"
jq '{error: .jobs[0].error, read: .jobs[0].read, write: .jobs[0].write}' \
    "$result_dir/fio.json" >"$result_dir/summary.json"
cat "$result_dir/summary.json"
[[ "$error" == 0 ]]
