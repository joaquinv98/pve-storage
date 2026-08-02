#!/bin/sh
set -eu

workdir="${WORKDIR:-/home/sysadmin/zfsnvme-io}"
count="${1:-128}"

mkdir -p "$workdir"
rm -f "$workdir/io.stop" "$workdir/io.log" "$workdir/io.sha" "$workdir/io.counter"
printf 'RUNNING\n' >"$workdir/io.result"

on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL:%s\n' "$rc" >"$workdir/io.result"
    fi
}
trap on_exit EXIT

iteration=0
while [ ! -f "$workdir/io.stop" ]; do
    dd if=/dev/urandom of="$workdir/io.bin" bs=1M count="$count" conv=fsync \
        >/dev/null 2>&1
    sha256sum "$workdir/io.bin" >"$workdir/io.sha"
    sha256sum -c "$workdir/io.sha" >/dev/null
    iteration=$((iteration + 1))
    printf '%s %s\n' "$iteration" "$(date --iso-8601=ns)" >"$workdir/io.counter"
done

printf 'PASS\n' >"$workdir/io.result"
