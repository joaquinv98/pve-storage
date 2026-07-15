#!/bin/sh

set -eu

workdir=/home/cirros
count="${1:-64}"

rm -f "$workdir/io.stop" "$workdir/io.log" "$workdir/io.sha" "$workdir/io.counter"
echo RUNNING >"$workdir/io.result"

on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL:$rc" >"$workdir/io.result"
    fi
}
trap on_exit EXIT

while [ ! -f "$workdir/io.stop" ]; do
    dd if=/dev/urandom of="$workdir/io.bin" bs=1M count="$count" conv=fsync >/dev/null 2>&1
    sha256sum "$workdir/io.bin" >"$workdir/io.sha"
    sha256sum -c "$workdir/io.sha" >/dev/null
    date +%s >"$workdir/io.counter"
done

echo PASS >"$workdir/io.result"
